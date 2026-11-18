#!/usr/bin/env python3
"""Load Boris's carrier rulings from a tab- or comma-separated file.

WHY A LOADER AND NOT A LIST OF INSERTS

Boris annotated the crosswalk in a spreadsheet. The annotations reached me as
an image with the right-hand columns cut off, so the GROUPS he used are known
and the VALUES are not. Rather than transcribe values I cannot read, this
reads his file.

THE FILE FORMAT

Either a 2, 3 or 4 column file, with or without a header:

    itdk_domain  decision  value  note

decision is one of:

    not_an_isp            value ignored. The domain is dropped from the
                          crosswalk and from step 2 entirely.
    use_bdc_name          value is a BDC provider name, verbatim. A domain
                          may have MANY of these: Boris mapped each of five
                          domains onto fifteen Windstream subsidiaries.
    use_bdc_of_asn        value is an AS NUMBER. The carrier's BDC name is
                          that of the operator of that ASN. Boris
                          2026-11-17: "use the NAME IN BDC of the operator
                          of the shown ASN". Digits only, with or without a
                          leading AS.
    use_bdc_provider      value is the BDC provider_id Boris chose.
    reject_bdc_provider   value is a BDC provider_id that must stop being
                          proposed.

GROUP FORM IS ALSO ACCEPTED, because that is the shape of his sheet: a line
whose first field is a decision name and whose remaining fields are empty
sets the decision for every following row until the next such line. So this
is valid input:

    not_an_isp
    musiciansgig.net
    ppe.com
    use_bdc_name	Windstream Alabama, LLC
    uniti.net
    netaxs.com

WHAT IT WILL NOT DO

It will not invent a value. A row needing one and lacking one is reported and
skipped, with the line number, and the run exits nonzero. A decision name it
does not recognise is reported rather than guessed at.

USAGE

  python3 load_decisions.py --file /home/boris/geo/logs/decisions.tsv
  python3 load_decisions.py --file ... --dry-run
  python3 load_decisions.py --show
"""

import argparse
import csv
import io
import os
import subprocess
import sys

NEEDS_VALUE = {"use_bdc_name", "use_bdc_of_asn", "use_bdc_provider",
               "reject_bdc_provider"}
NO_VALUE = {"not_an_isp"}
VALID = NEEDS_VALUE | NO_VALUE

NUMERIC_VALUE = {"use_bdc_provider", "reject_bdc_provider",
                 "use_bdc_of_asn"}


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def sniff(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        sample = f.read(8192)
    if "\t" in sample.splitlines()[0] if sample.splitlines() else False:
        return "\t"
    return ","


def parse(path):
    """Return (rows, problems). rows are (domain, decision, value, note)."""
    delim = sniff(path)
    rows = []
    problems = []
    current = None
    current_value = None

    with open(path, newline="", encoding="utf-8-sig") as f:
        for n, fields in enumerate(csv.reader(f, delimiter=delim), 1):
            fields = [(x or "").strip() for x in fields]
            while fields and fields[-1] == "":
                fields.pop()
            if not fields:
                continue

            first = fields[0]
            low = first.lower()

            # A header line.
            if n == 1 and low in ("itdk_domain", "domain"):
                continue

            # A GROUP line: a bare decision name, optionally with its value.
            if low in VALID and (len(fields) == 1 or len(fields) == 2):
                current = low
                current_value = fields[1] if len(fields) == 2 else None
                if current in NEEDS_VALUE and not current_value:
                    problems.append(
                        f"line {n}: group '{current}' needs a value on the "
                        f"same line, for example "
                        f"'{current}{delim}Windstream'. Nothing after this "
                        f"line was loaded under it.")
                    current = None
                continue

            # A per-row line.
            domain = first
            if len(fields) >= 2 and fields[1].lower() in VALID:
                decision = fields[1].lower()
                value = fields[2] if len(fields) > 2 else None
                note = fields[3] if len(fields) > 3 else None
            elif current:
                decision = current
                value = current_value
                note = fields[1] if len(fields) > 1 else None
            else:
                problems.append(
                    f"line {n}: '{domain}' has no decision, and no group "
                    f"line precedes it. Skipped rather than guessed.")
                continue

            if decision not in VALID:
                problems.append(
                    f"line {n}: decision '{decision}' is not recognised. "
                    f"Valid: {', '.join(sorted(VALID))}")
                continue
            if decision in NEEDS_VALUE and not value:
                problems.append(
                    f"line {n}: '{domain}' with decision '{decision}' needs "
                    f"a value and has none. Skipped rather than guessed.")
                continue
            if decision == "use_bdc_of_asn" and value:
                # His sheet writes the ASN as AS7106 in the bdc_name cell,
                # so the prefix is stripped rather than rejected.
                v = str(value).strip()
                if v[:2].upper() == "AS":
                    v = v[2:].strip()
                value = v
            if decision in NUMERIC_VALUE and not str(value).isdigit():
                problems.append(
                    f"line {n}: '{domain}' decision '{decision}' needs a "
                    f"numeric provider_id, got {value!r}")
                continue
            if "." not in domain:
                problems.append(
                    f"line {n}: {domain!r} does not look like a DNS domain. "
                    f"Skipped. If it is one, say so and I will relax this.")
                continue

            rows.append((domain.lower(), decision,
                         None if decision in NO_VALUE else value, note))
    return rows, problems


def cmd_load(args):
    if not os.path.isfile(args.file):
        sys.exit(f"not a file: {args.file}")

    ok = psql_q("SELECT to_regclass('carrier_decision_tbl') IS NOT NULL")
    if ok != "t":
        sys.exit("carrier_decision_tbl does not exist. Apply the schema "
                 "first:\n  psql -X -P pager=off -f "
                 "geo/carrier_nodes/carrier_decisions.sql")

    rows, problems = parse(args.file)

    print(f"{len(rows)} decision(s) parsed from {args.file}")
    by = {}
    for _, d, _, _ in rows:
        by[d] = by.get(d, 0) + 1
    for d in sorted(by):
        print(f"  {d:<22} {by[d]}")

    if problems:
        print(f"\n{len(problems)} line(s) NOT loaded:")
        for p in problems:
            print(f"  {p}")

    # Which domains are not in the crosswalk at all. Reported, not refused:
    # a ruling can legitimately arrive before the domain is measured.
    doms = {d for d, _, _, _ in rows}
    if doms:
        inlist = "(" + ", ".join(
            "'" + d.replace("'", "''") + "'" for d in sorted(doms)) + ")"
        known = set(psql("-qtA", "-c",
                         "SELECT DISTINCT itdk_domain FROM "
                         f"carrier_crosswalk_tbl WHERE itdk_domain IN {inlist}"
                         ).split())
        missing = sorted(doms - known)
        if missing:
            print(f"\n{len(missing)} domain(s) ruled on but NOT present in "
                  f"carrier_crosswalk_tbl. The rulings are still stored and "
                  f"will apply when the domain appears:")
            for m in missing[:20]:
                print(f"  {m}")

    if args.dry_run:
        print("\n--dry-run: nothing was written.")
        if problems:
            sys.exit(1)
        return

    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for domain, decision, value, note in rows:
        w.writerow([domain, decision,
                    "" if value is None else value,
                    "" if note is None else note])

    sql = ("\\copy carrier_decision_stage (itdk_domain, decision, value, "
           "note) FROM STDIN WITH (FORMAT csv, NULL '')")
    psql("-qc", "DROP TABLE IF EXISTS carrier_decision_stage")
    psql("-qc", "CREATE UNLOGGED TABLE carrier_decision_stage "
                "(itdk_domain text, decision text, value text, note text)")
    proc = subprocess.Popen(
        ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", "-q",
         "-c", sql], stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    proc.stdin.write(buf.getvalue())
    proc.stdin.close()
    err = proc.stderr.read()
    if proc.wait() != 0:
        sys.exit(f"copy failed:\n{err.strip()}")

    # Upsert so a corrected ruling replaces the earlier one rather than
    # colliding with it.
    psql("-qc", """
INSERT INTO carrier_decision_tbl (itdk_domain, decision, value, note)
SELECT itdk_domain, decision, nullif(value, ''), nullif(note, '')
FROM carrier_decision_stage
ON CONFLICT (itdk_domain, decision, coalesce(value, ''))
DO UPDATE SET note = excluded.note, decided_at = now()""")
    psql("-qc", "DROP TABLE IF EXISTS carrier_decision_stage")

    n = psql_q("SELECT count(*) FROM carrier_decision_tbl")
    print(f"\ncarrier_decision_tbl now holds {n} decision(s)")
    print("\nEffect on the crosswalk:")
    print(psql("-c", """
SELECT (SELECT count(DISTINCT itdk_domain) FROM carrier_crosswalk_tbl)
           AS domains_in_crosswalk,
       (SELECT count(*) FROM carrier_decision_tbl
        WHERE decision = 'not_an_isp')  AS ruled_not_an_isp,
       (SELECT count(*) FROM carrier_decision_tbl
        WHERE decision = 'use_bdc_name') AS named_bdc_pairings,
       (SELECT count(DISTINCT carrier_label) FROM carrier_resolved)
           AS distinct_carriers_after"""))
    if problems:
        sys.exit(1)


def cmd_show(args):
    print(psql("-c", """
SELECT decision, count(*) AS domains,
       left(string_agg(itdk_domain, ', ' ORDER BY itdk_domain), 70) AS examples
FROM carrier_decision_tbl GROUP BY decision ORDER BY decision"""))
    print(psql("-c", """
SELECT itdk_domain, decision, value, left(coalesce(note, ''), 40) AS note
FROM carrier_decision_tbl ORDER BY decision, itdk_domain LIMIT 100"""))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    lo = sub.add_parser("load", help="load a decisions file")
    lo.add_argument("--file", required=True)
    lo.add_argument("--dry-run", action="store_true",
                    help="parse and report, write nothing")
    lo.set_defaults(func=cmd_load)

    sh = sub.add_parser("show", help="show what has been decided")
    sh.set_defaults(func=cmd_show)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
