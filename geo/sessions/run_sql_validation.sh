#!/bin/sh
# run_sql_validation.sh - execute analysis SQL against an empty fixture so
# errors are found before Boris runs anything.
#
# WHY
#
# institution_reconciliation.sql shipped on 2026-11-10 with a GROUP BY
# violation. PostgreSQL rejected the first statement, the temp table was never
# created, and all seven later sections failed on a missing relation. Reading
# the file did not catch it. Executing it would have, in one second.
#
# WHAT IT PROVES AND WHAT IT DOES NOT
#
# Proves: the file parses, every column and table it names resolves, aggregates
# and GROUP BY are legal, casts and types work, psql meta-commands are valid.
#
# Does NOT prove: that results are correct, that denominators are right, or
# that the query is fast. Every table is EMPTY, so timings and plans here say
# nothing about production. The four-hour query in
# rdap_filler_allocations.sql would pass this cleanly.
#
# USAGE
#
#   sh geo/sessions/run_sql_validation.sh                     validate all
#   sh geo/sessions/run_sql_validation.sh geo/landmarks/x.sql validate one
#
# Run from the repository root. Needs PGVAL_HOME pointing at an extracted
# PostgreSQL and a running server; see the setup block below for how that was
# built in the sandbox, since no package install was possible there.
#
# Exit 0 means every file ran with no ERROR. Exit 1 means at least one failed.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

PGVAL_HOME=${PGVAL_HOME:-/projects/sandbox/.pgtmp}
PGBIN="$PGVAL_HOME/pg/usr/bin"
PGSOCK="$PGVAL_HOME/sock"
PGDB=${PGDB:-sqlval}
PGUSER_V=${PGUSER_V:-pgval}

export LD_LIBRARY_PATH="$PGVAL_HOME/pg/usr/lib64"

if [ ! -x "$PGBIN/psql" ]; then
    echo "No psql at $PGBIN. Set PGVAL_HOME to an extracted PostgreSQL."
    exit 1
fi

# Start the server if it is not answering. In the sandbox the server does not
# survive between shell invocations, so every run must be prepared to start it.
# PostgreSQL refuses to run as root, hence setpriv dropping to nobody; the data
# directory and socket directory are chowned to match.
if ! "$PGBIN/pg_isready" -h "$PGSOCK" -U "$PGUSER_V" >/dev/null 2>&1; then
    mkdir -p "$PGVAL_HOME/data" "$PGSOCK"
    # Clear stale lock and pid files. In the sandbox the postmaster is killed
    # when the shell invocation ends rather than shut down, so it leaves a
    # socket lock behind and the next start fails with
    #   FATAL: lock file ".s.PGSQL.5432.lock" already exists
    # This is only reached when pg_isready has already failed, so there is no
    # live server whose files these could be.
    rm -f "$PGSOCK"/.s.PGSQL.* "$PGVAL_HOME/data/postmaster.pid"
    chown -R 65534:65534 "$PGVAL_HOME/data" "$PGSOCK" 2>/dev/null
    if [ ! -f "$PGVAL_HOME/data/PG_VERSION" ]; then
        setpriv --reuid=65534 --regid=65534 --clear-groups \
            env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
            "$PGBIN/initdb" -D "$PGVAL_HOME/data" -U "$PGUSER_V" --auth=trust >/dev/null 2>&1
    fi
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
        "$PGBIN/pg_ctl" -D "$PGVAL_HOME/data" -l "$PGVAL_HOME/data/server.log" \
        -o "-k $PGSOCK -h ''" -w start >/dev/null 2>&1
fi

if ! "$PGBIN/pg_isready" -h "$PGSOCK" -U "$PGUSER_V" >/dev/null 2>&1; then
    echo "Could not start the validation server. Last lines of its log:"
    tail -10 "$PGVAL_HOME/data/server.log" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

psql_q() {
    "$PGBIN/psql" -h "$PGSOCK" -U "$PGUSER_V" -d "$PGDB" -v ON_ERROR_STOP=0 "$@"
}

# Rebuild the fixture database from scratch so one file cannot leave state that
# makes the next one pass for the wrong reason.
"$PGBIN/psql" -h "$PGSOCK" -U "$PGUSER_V" -d postgres -qc "DROP DATABASE IF EXISTS $PGDB" >/dev/null 2>&1
"$PGBIN/psql" -h "$PGSOCK" -U "$PGUSER_V" -d postgres -qc "CREATE DATABASE $PGDB" >/dev/null 2>&1

# landmarks_usa and rdap_registrant_tbl come from the REAL DDL. Only the
# TABLESPACE clause is removed, because ts_large_data does not exist here.
for ddl in geo/landmarks/create_table_landmarks_usa.sql geo/rdap_registrant_tbl.sql; do
    if [ -f "$ddl" ]; then
        sed 's/^TABLESPACE .*$/;/' "$ddl" | psql_q -q -f - >/dev/null 2>&1
    fi
done

psql_q -q -f geo/sessions/validation_schema.sql >/dev/null 2>&1

missing=$(psql_q -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='landmarks_usa'" 2>/dev/null)
if [ "${missing:-0}" != "1" ]; then
    echo "FIXTURE FAILED: landmarks_usa was not created. Nothing below is meaningful."
    exit 1
fi

if [ -n "${1-}" ]; then
    files=$*
else
    files=$(find geo -name '*.sql' -type f \
            ! -name 'validation_schema.sql' \
            ! -name 'create_table_landmarks_usa.sql' \
            ! -name 'rdap_registrant_tbl.sql' | sort)
fi

status=0
for f in $files; do
    err=$(psql_q -f "$f" 2>&1 | grep -E '^psql:.*(ERROR|FATAL)' || true)
    if [ -n "$err" ]; then
        echo "FAIL $f"
        echo "$err" | head -6 | sed 's/^/    /'
        status=1
    else
        echo "ok   $f"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "sql validation: all files executed with no ERROR"
fi

exit "$status"
