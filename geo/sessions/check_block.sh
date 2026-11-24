#!/bin/sh
# check_block.sh
#
# Mechanically check a command block BEFORE issuing it to Boris.
#
# Why this exists. He asked on 2026-11-24 how to force standing-orders
# compliance, after I shipped a placeholder he pasted verbatim and handed him
# a 519-million-row scan with no warning. The orders I made mechanical
# stopped being broken; check_sql.sh caught my own unbalanced apostrophes the
# day I wrote it. The orders that lived only in prose kept being broken. So
# the prose ones are checked here.
#
# Usage, writing the intended block to a file first:
#   sh /home/boris/geo/src/claude/geo/sessions/check_block.sh /tmp/block.txt
#
# Exits non-zero and names every violation. It does not run anything.

if [ -z "$1" ]; then
    echo "check_block: give me the file holding the command block" >&2
    exit 2
fi
f="$1"
if [ ! -f "$f" ]; then
    echo "check_block: no such file: $f" >&2
    exit 2
fi

bad=0

report() {
    echo "check_block: $1"
    bad=1
}

# 1. PLACEHOLDERS. He pastes verbatim, so a slot becomes a literal.
if grep -nE "SHEETNAME|YOUR_|/path/to/|A\.B\.C\.D|1\.2\.3\.4|postgres://|<[a-zA-Z_]+>|\\\$\\{?[A-Z_]*PLACEHOLDER" "$f"; then
    report "a placeholder. Ask for the value or make the tool find it."
fi

# 2. MID-LINE HASH. His paste path strips from a mid-line hash to end of line.
if grep -nE "^[^#]*[^[:space:]#]+.*#" "$f"; then
    report "a mid-line hash, which his paste path deletes to end of line."
fi

# 3. BACKSLASH. Converted in transit. A psql backslash command at the start
# of a line is not affected, so only mid-line backslashes are reported.
if grep -nE "^[^\\\\]*[^[:space:]\\\\]+.*\\\\" "$f"; then
    report "a mid-line backslash, which his paste path converts."
fi

# 4. SUDO WITHOUT CACHING FIRST.
if grep -q "sudo" "$f"; then
    if [ "$(grep -c '^sudo -v$' "$f")" -eq 0 ]; then
        report "sudo without 'sudo -v' on its own first line."
    fi
fi

# 5. RELATIVE PATHS after the commands that take a file.
if grep -nE "(psql +-f|python3|sh) +[^/ ][^ ]*" "$f" | grep -vE "psql +-f +/|python3 +/|sh +/|python3 +-c|python3 +-u +/" ; then
    report "a relative path. Every block is pasted independently, so a cd in an earlier block does not carry."
fi

# 6. A REPORT WITHOUT A LOG. Any psql that runs a file or prints a result
# must tee somewhere, or the output is lost the moment the terminal scrolls.
if grep -qE "psql +(-f|-c)" "$f"; then
    if ! grep -q "tee" "$f"; then
        report "a psql report with no tee. Send it to /home/boris/geo/logs/."
    fi
fi

# 7. FENCED OUTPUT. A line that looks like a psql result table is program
# output, and he pastes fenced blocks into a shell.
if grep -nE "^ *[-+]{4,}\+|^ *\([0-9]+ rows?\)" "$f"; then
    report "program output, not a command. He pastes blocks verbatim."
fi

if [ "$bad" -eq 0 ]; then
    echo "check_block: clean"
    exit 0
fi
echo "check_block: FIX THESE BEFORE SENDING"
exit 1
