# Pipeline scheduling

Three cadences, deliberately kept as separate jobs because their runtimes differ
by orders of magnitude.

| script | cadence | typical runtime | what it does |
| --- | --- | --- | --- |
| `daily_pipeline.sh` | daily | 25 to 45 min | RouteViews import, split detection, /24 decomposition |
| `probe_batch.sh` | hourly | about 60 min | one bounded batch of ip-api lookups |
| `dbip-mmdb-import` | monthly | 10 to 20 min | replace db-ip rows from the new edition |

## Why probing is not inside the daily job

The free ip-api tier allows 45 calls a minute, so a backlog of a few hundred
thousand ranges takes days. Putting that inside a daily job would mean every run
overlapping the next. `probe_batch.sh` instead does exactly one hour of work per
invocation (2700 lookups) and takes a lock, so hourly cron sustains the maximum
free rate and never exceeds it.

## Crontab

Adjust paths if `GEO_HOME` is not `$HOME/geo`. `DATABASE_URL` must be visible to
cron, which does not read your shell profile, so set it in the crontab itself.

    DATABASE_URL=postgresql://user:password@host:5432/dbname

    # daily: RouteViews to /24 rows, 03:20 UTC
    20 3 * * *   /home/boris/geo/pipeline/daily_pipeline.sh

    # hourly: one hour of ip-api lookups, offset to avoid the daily run
    5 * * * *    /home/boris/geo/pipeline/probe_batch.sh

    # monthly: new db-ip edition, 2nd of the month at 04:15 UTC
    15 4 2 * *   /home/boris/geo/dbip-mmdb-import/bin/dbip-mmdb-import -preserve-routeviews all

The `DATABASE_URL=` line above is a template. Substitute your real connection
string; it is not a value to paste as-is.

## Order matters within the daily job

1. **RouteViews import** must precede split detection, or detection runs against
   yesterday's routing table.
2. **Split detection** must precede decomposition, since `apply_splits` reads
   `dbip_split_candidates`.
3. **Decomposition** must precede probing, because probing selects from
   `ip2city_dbiplite_tbl` and the /24 rows have to exist first.

The script enforces this by failing the whole run if any step exits non-zero,
rather than letting a later step act on stale or partial data.

## The monthly import needs -preserve-routeviews all

Default `conditional` keeps a RouteViews /24 only if the new db-ip edition still
has a strictly wider row covering it. `apply_splits` **deletes** those parents, so
under the default nearly every /24 row would be discarded and the probe
investment lost. Use `all` for as long as `apply_splits` deletes parents. The
importer warns when it drops every RouteViews row.

## After each monthly import

`dbip_split_candidates` is stale, because the db-ip baseline changed. The next
daily run rebuilds it, so no manual step is needed. What is worth doing manually
is a fresh classification pass, since a new edition can introduce wide ranges
never triaged before:

    ~/geo/classify_ranges/bin/classify_ranges -max-masklen 20
    # review, then
    ~/geo/classify_ranges/bin/classify_ranges -recheck -auto-exclude

Deliberately not in the daily job: it spends probes from the same 45/min budget
as geolocation, and the candidate set only changes materially after a monthly
import.

## Checking state

    ~/geo/pipeline/probe_batch.sh --remaining      # backlog and days to clear
    tail -40 ~/geo/logs/daily_pipeline.log
    tail -40 ~/geo/logs/probe_batch.log

    -- provenance of the range table
    SELECT source, count(*) FROM ip2city_dbiplite_tbl GROUP BY 1;

    -- geolocation progress
    SELECT count(*) FILTER (WHERE city IS NOT NULL) AS with_city,
           count(*) AS rows
    FROM ip2city_dbiplite_traceroute_tbl;

## Known wart

`check_range_splits` flags any db-ip range containing two or more more-specific
BGP prefixes, including the /24 rows `apply_splits` has already created, when BGP
carries prefixes longer than /24 inside them (about 2,310 such prefixes exist).
`apply_splits` then skips them, since a /24 has nothing to decompose. So
`dbip_split_candidates` accumulates a stable set of entries that are counted but
never actioned. Harmless, but it inflates the candidate count and is worth
remembering when reading the numbers.
