Coverage runbook: what to run, in what order, and why
=====================================================

Written 2026-11-05 from measured output. Every command here was derived from
source read in this repository, not from recollection. Where something is
unverified it says so.

A NOTE ON OUTPUT. Several of these print long lists through a pager, and a
pager's output cannot be copied out of a terminal session. Every command below
therefore writes to a file under /home/boris/geo/logs and shows only the tail,
so the full output survives and the summary is still visible.

    mkdir -p /home/boris/geo/logs


Why coverage is measured in ZIP-and-ISP pairs
---------------------------------------------

A landmark yields a ZIP for ONE carrier's access network. The method is
node-to-node: mtr the landmark, keep the last carrier node before the customer
equipment, and label probe ranges whose node is the SAME node. That node belongs
to one ISP, so a landmark on one carrier says nothing about the others serving
the same ZIP.

Measured from the probe table's own ip-api isp column, which is populated on
1,014,998 of 1,015,278 ranges carrying a ZIP:

    (ZIP, ISP) pairs          126,169
    ZIPs                       21,665
    mean ISPs per ZIP            5.82
    ZIPs served by one ISP      6,885 of 21,665

So the denominator is not 41,700 ZIPs, it is of the order of 126,000 pairs, and
a ZIP is not finished when its first landmark lands.

ENTERPRISE ALLOCATIONS COUNT. There is at-work media use and it has to be
captured, so a registrant being a business rather than a consumer ISP does not
disqualify it. Measured, the enterprise and unclassified block is the LARGEST in
the uncovered queue at 54.1M addresses over 1,047 pairs, against the known ISPs'
47.3M over 7,574. Only CDN, cloud and web hosts in provider_names are genuinely
unreachable, and for rule 2's reason: a provider's adjacent node is an edge
router that routes content and never subscribers, so retail routing cannot
converge through it. That block is 202 pairs.


The node fan-out result, and what actually limits coverage
----------------------------------------------------------

node_fanout.sql, run 2026-11-05 against landmarks_usa, built
address_hosting_tbl with 6,261 rows and classified the carrier nodes:

    verdict                           nodes   landmarks   pct
    unmeasured: too few landmarks     4,940       5,949   35.7
    reject: too wide to cluster          19       2,087   12.5
    zip-level: one contiguous area      307       1,893   11.4
    reject: 3 disjoint areas            323       1,329    8.0
    reject: 4 disjoint areas            174         910    5.5
    reject: 2 disjoint areas            203         836    5.0
    (the remaining reject buckets run from 5 to 37 disjoint areas)

THE USABLE SET IS 307 NODES. Everything else is either rejected as a shared host
or cannot be judged at all.

THE LARGEST SINGLE BUCKET IS "UNMEASURED: TOO FEW LANDMARKS", at 4,940 nodes
covering 35.7 percent of landmarks. These are carrier nodes already traced and
already adjacent to customer premises, which cannot be classified because only
one or two landmarks sit behind each. node_fanout.sql's own header states the
reason: a fan-out figure computed from one landmark is not a measurement, which
is why every query there reports landmarks-per-node beside the fan-out.

That reframes what the state school ingest is for. Its value is not only the new
ZIPs it adds. It is that 4,940 already-traced nodes become MEASURABLE once
enough landmarks sit behind each one, and a node that resolves to "one
contiguous area" converts directly into ZIP labels for every probe range sharing
it. Adding landmarks in ZIPs that already have one is therefore productive,
which the ZIP-counting metric made look like waste.


Step 1. Restore the hosting verdicts
------------------------------------

Run this from main, NOT from a feature branch. The preservation guard in
ovt_resolve_hosts.py arrived in commit 99e8206 on 2026-10-31, titled
"onpremises: stop reverting the hosting rule", and git merge-base shows that
commit is NOT an ancestor of geo-ca-cde-schools. The California chain was run
from that branch, so the pre-guard onpremises step ran and reverted 66,923
hosting verdicts to true. Checking before each chain run costs nothing:

    cd /home/boris/geo/src/claude
    git branch --show-current
    grep -c "NOT LIKE 'hosting:%'" geo/overture_fetch/ovt_resolve_hosts.py

That count must be 1 or more. Then:

    sudo -v
    psql -d postgres -v ON_ERROR_STOP=1 -f /home/boris/geo/src/claude/geo/node_fanout.sql > /home/boris/geo/logs/node_fanout.log 2>&1
    tail -40 /home/boris/geo/logs/node_fanout.log
    psql -d postgres -v ON_ERROR_STOP=1 -f /home/boris/geo/src/claude/geo/landmarks/onpremises_hosting_rule.sql > /home/boris/geo/logs/hosting_rule.log 2>&1
    tail -40 /home/boris/geo/logs/hosting_rule.log

Expect places_set_false near 66,923 and onpremises true near 65,202. The rule is
idempotent: its WHERE admits a row that is true with a hosting reason, so
re-running re-decides cleanly.


Step 2. Fill the RDAP cache
---------------------------

WHY. rdap_registrant_tbl is 272 kB against a 661 MB probe table, and the
coverage query found only 89 distinct registrants nationally. Until it is
filled, the demand side is whatever the cache happens to hold and every
uncovered figure is a floor rather than a measurement.

THE FLAGS BELOW WERE READ FROM geo/rdap_registrant/cmd/main.go, lines 106 to
118, not recalled:

    -fill            walk the candidate set, querying only candidates no cached
                     allocation already covers
    -candidates T    table with a cidr column named network. EMPTY MEANS every
                     db-ip row wider than a /24, which is NOT what the coverage
                     query needs: it needs the probe ranges
    -limit N         stop after N queries, 0 means no limit
    -rate R          maximum requests per second, default 1.0. The source states
                     the RIR limits are UNVERIFIED for this project and the
                     default is deliberately slow
    -dry-run         query and write nothing, report how many candidates the
                     cache already covers
    -http-timeout    per request, default 30s

DATABASE_URL is read from the environment and falls back to libpq defaults, so
do not set it.

Size it first. Note the tool's own caveat, at main.go line 251: one query
returns an allocation that usually covers many later candidates, and a dry run
cannot know those boundaries, so the dry-run figure OVERSTATES the work:

    cd /home/boris/geo/src/claude/geo/rdap_registrant/cmd
    go run . -fill -candidates ip2city_dbiplite_probe_tbl -dry-run > /home/boris/geo/logs/rdap_dryrun.log 2>&1
    tail -20 /home/boris/geo/logs/rdap_dryrun.log

Then a bounded first batch, to see the real query-to-candidate ratio and whether
ARIN rate-limits before committing to a long run. 429s are reported in the
closing summary:

    cd /home/boris/geo/src/claude/geo/rdap_registrant/cmd
    go run . -fill -candidates ip2city_dbiplite_probe_tbl -limit 500 -rate 1 > /home/boris/geo/logs/rdap_500.log 2>&1
    tail -20 /home/boris/geo/logs/rdap_500.log

The line to read is "done: N already covered by cache, N queried, N failed, N
rate limited". If 500 queries covered far more than 500 candidates, the full run
is tractable; if rate limited is above zero, -rate has to come down before any
longer run. I have NOT measured ARIN's limit and will not guess at a higher
rate.


Step 3. Re-measure
------------------

    sudo -v
    psql -d postgres -v ON_ERROR_STOP=1 -f /home/boris/geo/src/claude/geo/landmarks/landmark_isp_coverage_followup.sql > /home/boris/geo/logs/coverage.log 2>&1
    tail -60 /home/boris/geo/logs/coverage.log

The figures to compare against, all measured 2026-11-05 BEFORE the hosting
verdicts were restored and BEFORE the cache was filled:

    supply as counted            56,040 pairs   16,114 ZIPs
    supply excluding hosting     20,958 pairs    9,730 ZIPs
    demand, RDAP-cache-limited   10,234 pairs
    pairs covered, as counted    29.03 percent
    pairs covered, clean supply  13.79 percent

The clean supply figure of 9,730 ZIPs reproduces the 9,728 recorded in the
Session 3 notes, which confirms that 9,728 was the hosting-rule-applied number
and 16,114 was the reverted one.


Still unverified
----------------

The SQL files in this directory have been checked structurally, statement by
statement, and every relation and column was confirmed against the DDL or
against live introspection output. They have NOT been execution-tested by the
author: no PostgreSQL is available in the authoring sandbox and its package
repository returns 403. Run them with -v ON_ERROR_STOP=1 so a mistake stops at
the first statement instead of cascading.
