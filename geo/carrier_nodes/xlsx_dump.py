"""
xlsx_dump.py

Read an .xlsx workbook using NOTHING BUT THE PYTHON STANDARD LIBRARY and
either describe its sheets or convert one sheet to TSV.

Why this exists. Boris supplied the FCC Form 499a filer list as
/home/boris/geo/FCC_Form_499a_filers.xlsx. An .xlsx file is a ZIP container
of XML parts, so it cannot be read with psql, sed or cat, and openpyxl is
not installed on either machine (verified 2026-11-23: ModuleNotFoundError).
Installing a package to read one file is a worse trade than parsing the
parts, which are a documented format.

It does not guess at the shape of the file. Run it in describe mode first,
look at the sheet names and the header row, and only then convert. The SQL
loader is written against what the header row actually says.

USAGE, describe every sheet and show the first rows of each:

    python3 xlsx_dump.py --describe /home/boris/geo/FCC_Form_499a_filers.xlsx

USAGE, convert one sheet to a TSV that psql can COPY:

    python3 xlsx_dump.py --sheet 'Sheet1' --out /home/boris/geo/fcc499.tsv /home/boris/geo/FCC_Form_499a_filers.xlsx

Values are emitted exactly as the file stores them, with one exception: a
tab, carriage return or newline inside a cell is replaced by a single space,
because those three characters would corrupt a TSV. The substitution is
counted and reported on stderr so it is never silent.

Numbers are emitted as the literal text the file holds. A cell formatted as
a date is stored as a serial number, so a date column will come out as a
number; say so rather than inventing a conversion that might be wrong by a
day or by four years.
"""

import argparse
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
PKG_REL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"
DOC_REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"

CELL_REF_RE = re.compile(r"^([A-Z]+)")


def column_index(cell_ref):
    """A1 to 0, B1 to 1, AA1 to 26. Needed because a row omits empty cells,
    so position has to be recovered from the reference rather than counted."""
    match = CELL_REF_RE.match(cell_ref or "")
    if not match:
        return None
    index = 0
    for char in match.group(1):
        index = index * 26 + (ord(char) - ord("A") + 1)
    return index - 1


def read_shared_strings(archive):
    """The shared string table. A cell with t="s" holds an index into this
    list rather than its own text. An entry can be split into several runs by
    formatting, so every t descendant is concatenated."""
    name = "xl/sharedStrings.xml"
    if name not in archive.namelist():
        return []
    strings = []
    root = ET.fromstring(archive.read(name))
    for item in root.findall(MAIN_NS + "si"):
        parts = [node.text or "" for node in item.iter(MAIN_NS + "t")]
        strings.append("".join(parts))
    return strings


def read_sheet_index(archive):
    """Sheet display names in workbook order, each with the part that holds
    it. The name to part mapping goes through the relationship file, so it
    cannot be assumed that the second sheet lives in sheet2.xml."""
    rels = {}
    rels_part = "xl/_rels/workbook.xml.rels"
    if rels_part in archive.namelist():
        root = ET.fromstring(archive.read(rels_part))
        for rel in root.findall(PKG_REL_NS + "Relationship"):
            target = rel.get("Target") or ""
            if target.startswith("/"):
                target = target.lstrip("/")
            elif not target.startswith("xl/"):
                target = "xl/" + target
            rels[rel.get("Id")] = target

    sheets = []
    root = ET.fromstring(archive.read("xl/workbook.xml"))
    container = root.find(MAIN_NS + "sheets")
    if container is None:
        return sheets
    for sheet in container.findall(MAIN_NS + "sheet"):
        rel_id = sheet.get(DOC_REL_NS + "id")
        part = rels.get(rel_id)
        if part is None or part not in archive.namelist():
            continue
        sheets.append((sheet.get("name") or "", part))
    return sheets


def cell_text(cell, shared):
    """The text of one cell. t="s" is a shared string index, t="inlineStr"
    carries its own is/t element, anything else keeps the literal v text."""
    kind = cell.get("t")
    if kind == "s":
        node = cell.find(MAIN_NS + "v")
        if node is None or node.text is None:
            return ""
        try:
            return shared[int(node.text)]
        except (ValueError, IndexError):
            return ""
    if kind == "inlineStr":
        holder = cell.find(MAIN_NS + "is")
        if holder is None:
            return ""
        return "".join(node.text or "" for node in holder.iter(MAIN_NS + "t"))
    node = cell.find(MAIN_NS + "v")
    if node is not None and node.text is not None:
        return node.text
    node = cell.find(MAIN_NS + "t")
    if node is not None and node.text is not None:
        return node.text
    return ""


def iter_rows(archive, part, shared):
    """Yield one list of strings per row, with omitted cells restored as
    empty strings so column positions survive. iterparse keeps memory flat,
    because a filer list can be long."""
    with archive.open(part) as handle:
        row = None
        width = 0
        for event, node in ET.iterparse(handle, events=("start", "end")):
            if event == "start" and node.tag == MAIN_NS + "row":
                row = {}
                width = 0
            elif event == "end" and node.tag == MAIN_NS + "c":
                if row is not None:
                    position = column_index(node.get("r"))
                    if position is None:
                        position = width
                    row[position] = cell_text(node, shared)
                    width = max(width, position + 1)
                node.clear()
            elif event == "end" and node.tag == MAIN_NS + "row":
                yield [row.get(i, "") for i in range(width)] if row else []
                row = None
                node.clear()


SUBSTITUTE_RE = re.compile(r"[\t\r\n]")


def clean(value, counter):
    cleaned, hits = SUBSTITUTE_RE.subn(" ", value)
    counter[0] += hits
    return cleaned


def check_readable(path):
    """Say what is wrong in one line instead of raising a traceback.

    Boris 2026-11-23 ran this against a path that did not exist and got a
    nine line FileNotFoundError out of zipfile. A tool that takes a path has
    to check the path. It also lists the workbooks that ARE in the directory,
    which is reported fact rather than a guess about where the file went."""
    import os

    if not os.path.exists(path):
        directory = os.path.dirname(os.path.abspath(path)) or "."
        message = ["this file does not exist: " + path]
        if os.path.isdir(directory):
            found = sorted(entry for entry in os.listdir(directory)
                           if entry.lower().endswith((".xlsx", ".xls", ".xlsm",
                                                      ".csv", ".zip")))
            if found:
                message.append("the spreadsheet-like files in " + directory
                               + " are: " + ", ".join(found))
            else:
                message.append("there are no .xlsx, .xls, .csv or .zip files in "
                               + directory)
        else:
            message.append("and its directory does not exist either: " + directory)
        message.append("nothing was read and nothing was written")
        raise SystemExit("\n".join(message))

    if os.path.isdir(path):
        raise SystemExit(path + " is a directory, not a workbook."
                         " Nothing was read.")

    if os.path.getsize(path) == 0:
        raise SystemExit(path + " is zero bytes long, so the transfer did not"
                         " complete. Nothing was read.")

    if not zipfile.is_zipfile(path):
        with open(path, "rb") as handle:
            head = handle.read(8)
        hint = ""
        if head[:5] == b"\xd0\xcf\x11\xe0\xa1":
            hint = (" The first bytes are the old Excel 97 format, so this is"
                    " a .xls and not a .xlsx. Open it and save as .xlsx, or"
                    " export it as CSV.")
        elif head[:1] in (b"<", b"\xef"):
            hint = " The first bytes look like text, so this may be an HTML or XML export."
        raise SystemExit(
            path + " is not a zip container, and every .xlsx is one."
            + hint + " First bytes: " + repr(head) + ". Nothing was read.")


def describe(path, preview_rows):
    check_readable(path)
    with zipfile.ZipFile(path) as archive:
        shared = read_shared_strings(archive)
        sheets = read_sheet_index(archive)
        print("file: " + path)
        print("shared strings: " + str(len(shared)))
        print("sheets: " + str(len(sheets)))
        for name, part in sheets:
            print("")
            print("sheet name: " + repr(name))
            print("  part: " + part)
            rows = 0
            widest = 0
            shown = 0
            for row in iter_rows(archive, part, shared):
                rows += 1
                widest = max(widest, len(row))
                if shown < preview_rows:
                    shown += 1
                    cells = [repr(value) for value in row]
                    print("  row " + str(rows) + ": " + ", ".join(cells))
            print("  total rows: " + str(rows))
            print("  widest row: " + str(widest) + " columns")


def convert(path, sheet_name, out_path):
    with zipfile.ZipFile(path) as archive:
        shared = read_shared_strings(archive)
        sheets = read_sheet_index(archive)
        wanted = None
        for name, part in sheets:
            if name == sheet_name:
                wanted = part
                break
        if wanted is None:
            available = ", ".join(repr(name) for name, _ in sheets)
            raise SystemExit(
                "no sheet named " + repr(sheet_name)
                + ". The sheets in this file are: " + available
                + ". Nothing was written."
            )
        substitutions = [0]
        written = 0
        with open(out_path, "w", encoding="utf-8") as out:
            for row in iter_rows(archive, wanted, shared):
                out.write("\t".join(clean(value, substitutions) for value in row))
                out.write("\n")
                written += 1
        sys.stderr.write(
            "wrote " + str(written) + " rows to " + out_path + "\n")
        if substitutions[0]:
            sys.stderr.write(
                "replaced " + str(substitutions[0])
                + " tab or newline characters inside cells with a space\n")


RESERVED = {"all", "and", "as", "asc", "case", "cast", "check", "column",
            "constraint", "create", "default", "desc", "distinct", "do",
            "else", "end", "false", "for", "from", "group", "having", "in",
            "is", "join", "limit", "not", "null", "offset", "on", "or",
            "order", "primary", "references", "select", "table", "then",
            "to", "true", "union", "unique", "user", "using", "when",
            "where", "with"}


def identifier(label, position, used):
    """A header cell turned into a column name. Lower case, runs of anything
    that is not a letter or a digit collapsed to one underscore. A name that
    would start with a digit, collide with another column, hit the 63 byte
    identifier limit or land on a reserved word gets a safe form instead.
    Nothing here invents a column name from knowledge of the file; it only
    reshapes what the header row says."""
    base = re.sub(r"[^a-z0-9]+", "_", (label or "").strip().lower()).strip("_")
    if not base:
        base = "column_" + str(position + 1)
    if base[0].isdigit():
        base = "c_" + base
    if base in RESERVED:
        base = base + "_col"
    base = base[:60]
    name = base
    suffix = 2
    while name in used:
        name = base[:57] + "_" + str(suffix)
        suffix += 1
    used.add(name)
    return name


def looks_like_header(row):
    return sum(1 for value in row if value.strip()) >= 2


def choose_sheet(path, requested):
    """Which sheet to read. If the caller named one, that one, and the error
    names the real alternatives if it is absent. If not, the only sheet that
    HAS data, and a refusal naming the choices when there is more than one.

    This exists so the command needs no placeholder. I told Boris to paste a
    command containing --sheet 'SHEETNAME' and he pastes commands verbatim,
    which is a standing order I had already been given and broke. A tool that
    cannot work out its own default is a tool that forces a placeholder."""
    check_readable(path)
    with zipfile.ZipFile(path) as archive:
        shared = read_shared_strings(archive)
        sheets = read_sheet_index(archive)
        if not sheets:
            raise SystemExit("this workbook has no sheets at all. Nothing was read.")

        if requested:
            for name, part in sheets:
                if name == requested:
                    return name, part
            raise SystemExit(
                "no sheet named " + repr(requested) + ". The sheets in this"
                " file are: " + ", ".join(repr(name) for name, _ in sheets)
                + ". Nothing was written.")

        with_data = []
        for name, part in sheets:
            rows = 0
            for row in iter_rows(archive, part, shared):
                if any(value.strip() for value in row):
                    rows += 1
                if rows > 1:
                    break
            if rows > 1:
                with_data.append((name, part))

        if len(with_data) == 1:
            sys.stderr.write("one sheet holds data, using it: "
                             + repr(with_data[0][0]) + "\n")
            return with_data[0]
        if not with_data:
            raise SystemExit(
                "no sheet in this workbook holds more than one non-empty row,"
                " so there is nothing to load. Nothing was written.")
        raise SystemExit(
            "this workbook has " + str(len(with_data)) + " sheets holding data: "
            + ", ".join(repr(name) for name, _ in with_data)
            + ". Re-run with --sheet followed by the one you want, copying the"
            " name exactly as printed above. Nothing was written.")


def write_loader(path, part, sheet_name, table, tsv_path, sql_path, header_row):
    """Write the TSV and a SQL file that loads it, with the column names and
    the column COUNT taken from the header row of the sheet. Every column is
    text: a filer list is names and identifiers, and a numeric type guessed
    from the first few rows is how a leading zero on an FRN gets destroyed."""
    with zipfile.ZipFile(path) as archive:
        shared = read_shared_strings(archive)
        sheets = read_sheet_index(archive)

        header = None
        header_at = 0
        rows_seen = 0
        substitutions = [0]
        data_rows = 0
        ragged_short = 0
        ragged_long = 0
        dropped_blank = 0

        with open(tsv_path, "w", encoding="utf-8") as out:
            for row in iter_rows(archive, part, shared):
                rows_seen += 1
                if header is None:
                    take = (rows_seen == header_row) if header_row \
                        else looks_like_header(row)
                    if not take:
                        continue
                    header = [clean(value, substitutions) for value in row]
                    while header and not header[-1].strip():
                        header.pop()
                    if not header:
                        raise SystemExit(
                            "the header row is empty. Nothing was written.")
                    header_at = rows_seen
                    continue
                values = [clean(value, substitutions) for value in row]
                if not any(value.strip() for value in values):
                    dropped_blank += 1
                    continue
                if len(values) < len(header):
                    ragged_short += 1
                    values = values + [""] * (len(header) - len(values))
                elif len(values) > len(header):
                    ragged_long += 1
                    values = values[:len(header)]
                out.write("\t".join(values))
                out.write("\n")
                data_rows += 1

    if header is None:
        raise SystemExit("found no header row in sheet " + repr(sheet_name)
                         + ". Nothing was written.")

    used = set()
    columns = [identifier(label, i, used) for i, label in enumerate(header)]

    with open(sql_path, "w", encoding="utf-8") as sql:
        sql.write("-- Generated by xlsx_dump.py from " + path + "\n")
        sql.write("-- sheet " + repr(sheet_name) + ", header taken from row "
                  + str(header_at) + "\n")
        sql.write("-- The column names below are the header cells of that row,\n")
        sql.write("-- lowercased with punctuation turned into underscores. They\n")
        sql.write("-- were not chosen by hand and nothing was assumed about the file.\n")
        for label, column in zip(header, columns):
            sql.write("--   " + repr(label) + " becomes " + column + "\n")
        sql.write("\n\\set ON_ERROR_STOP on\n\n")
        sql.write("DROP TABLE IF EXISTS " + table + ";\n")
        sql.write("CREATE TABLE " + table + " (\n")
        sql.write(",\n".join("    " + column + " text" for column in columns))
        sql.write(");\n\n")
        sql.write("\\copy " + table + " FROM '" + tsv_path
                  + "' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b', HEADER false)\n\n")
        sql.write("ANALYZE " + table + ";\n\n")
        sql.write("SELECT count(*) AS rows_loaded FROM " + table + ";\n")

    report = sys.stderr.write
    report("header found on row " + str(header_at) + " with "
           + str(len(header)) + " columns\n")
    report("columns: " + ", ".join(columns) + "\n")
    report("wrote " + str(data_rows) + " data rows to " + tsv_path + "\n")
    report("wrote the loader to " + sql_path + "\n")
    if dropped_blank:
        report("skipped " + str(dropped_blank) + " entirely empty rows\n")
    if ragged_short:
        report("padded " + str(ragged_short)
               + " rows that held fewer cells than the header\n")
    if ragged_long:
        report("TRUNCATED " + str(ragged_long) + " rows that held MORE cells than"
               " the header. Check the header row choice before trusting these.\n")
    if substitutions[0]:
        report("replaced " + str(substitutions[0])
               + " tab or newline characters inside cells with a space\n")


def main():
    parser = argparse.ArgumentParser(
        description="Describe or convert an xlsx workbook using the standard library only.")
    parser.add_argument("workbook")
    parser.add_argument("--describe", action="store_true",
                        help="list the sheets and show the first rows of each")
    parser.add_argument("--preview", type=int, default=4,
                        help="how many rows to show per sheet in describe mode")
    parser.add_argument("--sheet", help="the sheet to convert, by its exact name")
    parser.add_argument("--out", help="where to write the TSV")
    parser.add_argument("--table",
                        help="also write a SQL loader for this table name, with"
                             " columns taken from the sheet's header row")
    parser.add_argument("--sql", help="where to write the SQL loader")
    parser.add_argument("--header-row", type=int, default=0,
                        help="which row holds the header, counting from 1."
                             " The default finds the first row with at least"
                             " two non-empty cells.")
    args = parser.parse_args()

    if args.table:
        if not (args.out and args.sql):
            raise SystemExit("--table needs --out and --sql."
                             " Nothing was written.")
        # --sheet is OPTIONAL: when the workbook holds data on one sheet only,
        # that is the sheet, and the command needs no placeholder.
        name, part = choose_sheet(args.workbook, args.sheet)
        write_loader(args.workbook, part, name, args.table, args.out,
                     args.sql, args.header_row)
        return

    if args.describe or not args.sheet:
        describe(args.workbook, args.preview)
        if not args.sheet:
            return
    if args.sheet:
        if not args.out:
            raise SystemExit("--sheet needs --out. Nothing was written.")
        convert(args.workbook, args.sheet, args.out)


if __name__ == "__main__":
    main()
