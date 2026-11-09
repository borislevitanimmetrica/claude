#!/bin/sh
# check_sql.sh - validate committed psql scripts before Boris runs them.
#
# WHY THIS EXISTS
#
# I shipped the same defect twice in one session: a backslash meta-command
# typed as \engine instead of \echo. psql reports "invalid command" and keeps
# going, so it does not fail the run, it just silently drops a line of the
# explanation the file exists to deliver. The second occurrence is what made
# this a tooling problem rather than a care problem.
#
# It also checks apostrophe quoting in \echo arguments. psql meta-command
# parsing is NOT SQL string parsing: inside single quotes, a doubled '' does
# not become a literal apostrophe, so "the row''s value" breaks the argument.
# A full SQL statement may use '' freely; only \echo lines are checked.
#
# Usage:
#   sh geo/sessions/check_sql.sh                 check every .sql under geo/
#   sh geo/sessions/check_sql.sh path/to/one.sql check one file
#
# Exit status 0 means clean, 1 means at least one problem was reported.
#
# Contains no mid-line hash and no backslash escapes in emitted text, so the
# usage lines above survive being pasted.

set -u

KNOWN='echo|timing|pset|set|unset|i|ir|o|qecho|if|elif|else|endif|copy|d|dt|df|du|dn|l|x|c|conninfo|gexec|gset|watch|crosstabview|password|encoding|pager|a|t|H|f|g'

status=0

if [ -n "${1-}" ]; then
    files=$*
else
    files=$(find geo -name '*.sql' -type f | sort)
fi

for f in $files; do
    bad_cmd=$(grep -n '^\\' "$f" | grep -Ev "^[0-9]+:\\\\($KNOWN)([ \t]|$)" || true)
    if [ -n "$bad_cmd" ]; then
        echo "UNKNOWN META-COMMAND in $f"
        echo "$bad_cmd" | sed 's/^/    /'
        status=1
    fi

    bad_quote=$(awk '/^\\echo/ { n = gsub(/'"'"'/, "&"); if (n % 2 != 0) printf "%d:%s\n", NR, $0 }' "$f" || true)
    if [ -n "$bad_quote" ]; then
        echo "UNBALANCED QUOTES in a psql echo argument in $f"
        echo "$bad_quote" | sed 's/^/    /'
        status=1
    fi

    doubled=$(grep -n "^\\\\echo .*''" "$f" | grep -v "^[0-9]*:\\\\echo ''$" || true)
    if [ -n "$doubled" ]; then
        echo "DOUBLED QUOTE inside a psql echo argument in $f"
        echo "    psql does not un-double these the way SQL does. Reword to avoid the apostrophe."
        echo "$doubled" | sed 's/^/    /'
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "check_sql: clean"
fi

exit "$status"
