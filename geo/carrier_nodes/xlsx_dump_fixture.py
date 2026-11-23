"""Build a real .xlsx by hand, to test xlsx_dump.py against the actual
format rather than against my idea of it. Deliberately includes the four
things that break a naive parser: a shared string table, an inline string,
a row that omits column B, and a cell holding a newline and a tab. The
second sheet is stored in a part whose name does not match its position,
so a parser that assumes sheet2.xml reads the wrong sheet."""

import zipfile

CT = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/zz_second.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="499A Filers" sheetId="1" r:id="rId1"/>
<sheet name="Notes &amp; Caveats" sheetId="2" r:id="rId2"/>
</sheets>
</workbook>"""

WB_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/zz_second.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>"""

SHARED = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="7" uniqueCount="7">
<si><t>Filer 499 ID</t></si>
<si><t>Legal Name</t></si>
<si><t>Doing Business As</t></si>
<si><r><t>AT&amp;T Enterpri</t></r><r><t>ses, LLC</t></r></si>
<si><t>AT&amp;T</t></si>
<si><t>Mediacom Communications Corporation</t></si>
<si><t>Line one
with a newline and a\ttab</t></si>
</sst>"""

SHEET1 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
<row r="2"><c r="A2"><v>808777</v></c><c r="B2" t="s"><v>3</v></c><c r="C2" t="s"><v>4</v></c></row>
<row r="3"><c r="A3"><v>811234</v></c><c r="C3" t="s"><v>5</v></c></row>
<row r="4"><c r="A4" t="inlineStr"><is><t>inline value</t></is></c><c r="B4" t="s"><v>6</v></c></row>
<row r="5"/>
<row r="6"><c r="AB6" t="str"><v>far right</v></c></row>
</sheetData>
</worksheet>"""

SHEET2 = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="inlineStr"><is><t>this is the second sheet</t></is></c></row>
</sheetData>
</worksheet>"""

with zipfile.ZipFile("/tmp/xlsx_dump_fixture.xlsx", "w") as z:
    z.writestr("[Content_Types].xml", CT)
    z.writestr("_rels/.rels", ROOT_RELS)
    z.writestr("xl/workbook.xml", WORKBOOK)
    z.writestr("xl/_rels/workbook.xml.rels", WB_RELS)
    z.writestr("xl/sharedStrings.xml", SHARED)
    z.writestr("xl/worksheets/sheet1.xml", SHEET1)
    z.writestr("xl/worksheets/zz_second.xml", SHEET2)
print("wrote /tmp/xlsx_dump_fixture.xlsx")
print("now run: python3 xlsx_dump.py --describe /tmp/xlsx_dump_fixture.xlsx")
