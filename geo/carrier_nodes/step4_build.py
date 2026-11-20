"""Step 4, built in reportable stages, per carrier AND TECHNOLOGY.

WHY THIS REPLACES THE SQL FILE'S SECTION 2b

Boris, 2026-11-18: "The last command is still running section 2b. You did not
advise time to completion or issue frequent feedback despite standing orders.
Should it continue running? No output in 8 minutes."

Both faults are mine.

THE PLAN WAS WRONG, not merely slow. Section 2b joined bdc_availability_tbl
to carrier_resolved_tbl and only then applied DISTINCT:

    SELECT DISTINCT r.itdk_domain, a.tract_geoid
    FROM bdc_availability_tbl a
    JOIN bdc_carrier_tbl c ON c.carrier_key = a.carrier_key
    JOIN carrier_resolved_tbl r ON r.bdc_provider_id = c.provider_id

His own run printed the numbers that condemn it: 11,916 resolved rows over 729
distinct bdc_provider_id, which is about SIXTEEN ITDK domains per provider. A
provider's availability rows are therefore multiplied by sixteen before the
DISTINCT removes them again. Xfinity alone has 37,980,045 records, so that is
six hundred million intermediate rows for one carrier.

The fix is to aggregate at PROVIDER level first, where the row count is
bounded by providers times technologies times tracts, and to attach the ITDK
domains afterwards, when there is almost nothing left to multiply.

NO PROGRESS WAS POSSIBLE FROM THAT STATEMENT. A single statement under
\\timing prints nothing until it completes. I knew that and issued it anyway.
This iterates over source_file_id, which has its own index, so each of the 333
files is an indexed read with a line of output and a running ETA.

TECHNOLOGY IS NOW A DIMENSION, which it was not before.

Boris, 2026-11-18: "We are assigning ZIP codes to sites per carrier &
technology."

Section 2b ignored technology entirely. That was wrong on the facts of the
plant: a carrier serves a tract over Copper from one facility and over Fiber
to the Premises from another, and the FCC records them as separate
technologies for that reason. His own technology table shows one carrier
under several codes, AT&T appearing as Licensed Fixed Wireless, Copper and
Fiber to the Premises with 53.6 million, 23.3 million and 20.8 million
records. Collapsing those would attribute a tract to whichever site happened
to be nearest regardless of whether that site carries the technology serving
it.

So the grain is (provider, technology, tract), and step 4's answer is per
carrier, per technology, per tract.

USAGE

  python3 -u step4_build.py pairs
  python3 -u step4_build.py pairs --resume
  python3 -u step4_build.py distances
  python3 -u step4_build.py report
"""

import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def script(name):
    return os.path.join(HERE, name)


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def require(table, remedy):
    if psql_q(f"SELECT to_regclass('{table}') IS NOT NULL") != "t":
        sys.exit(f"{table} does not exist.\n  {remedy}")


def cmd_pairs(args):
    """Aggregate availability to (provider, technology, tract), with progress.

    Iterated over source_file_id because bdc_availability_source_file_idx
    exists, so each file is an indexed read rather than a share of one
    opaque scan. 333 files, a line each, with a running rate and estimate.
    """
    require("bdc_availability_tbl", "Load the BDC first.")
    require("serving_site_tbl",
            f"psql -X -P pager=off -f {script('step4_tract_site.sql')}")

    psql("-qc", """
CREATE TABLE IF NOT EXISTS provider_tract_tech_tbl (
    provider_id integer NOT NULL,
    technology  smallint NOT NULL,
    tract_geoid text NOT NULL,
    PRIMARY KEY (provider_id, technology, tract_geoid));
CREATE TABLE IF NOT EXISTS provider_tract_done_tbl (
    source_file_id integer PRIMARY KEY,
    rows_added     bigint,
    seconds        double precision,
    done_at        timestamptz NOT NULL DEFAULT now());
COMMENT ON TABLE provider_tract_tech_tbl IS
  'One row per FCC provider_id, technology code and census tract in which that provider offers service over that technology. Aggregated at PROVIDER level deliberately: joining availability to the ITDK domains first multiplies every row by about sixteen, since 729 providers carry 11,916 resolved domain rows. Technology is a dimension because a carrier serves a tract over Copper from one facility and over fibre from another.';
COMMENT ON TABLE provider_tract_done_tbl IS
  'Which source files have been aggregated into provider_tract_tech_tbl, so the build resumes instead of restarting.';""")

    if not args.resume:
        n = psql_q("SELECT count(*) FROM provider_tract_tech_tbl")
        if n and n != "0":
            print(f"provider_tract_tech_tbl already holds {int(n):,} rows "
                  f"and {psql_q('SELECT count(*) FROM provider_tract_done_tbl')}"
                  f" file(s) are recorded as done.")
            print("Pass --resume to continue from there, which re-reads "
                  "nothing. Nothing has been changed.")
            return 1

    files = [r for r in psql("-qtAF|", "-c", """
SELECT f.source_file_id, f.source_file, coalesce(f.row_count, 0)
FROM bdc_source_file_tbl f
WHERE NOT EXISTS (SELECT 1 FROM provider_tract_done_tbl d
                  WHERE d.source_file_id = f.source_file_id)
ORDER BY coalesce(f.row_count, 0) DESC""").splitlines() if "|" in r]

    if not files:
        print("Every source file is already aggregated.")
        print(psql("-c", """
SELECT count(*) AS provider_tract_tech_rows,
       count(DISTINCT provider_id) AS providers,
       count(DISTINCT tract_geoid) AS tracts
FROM provider_tract_tech_tbl"""))
        return 0

    total_rows = 0
    for r in files:
        p = r.split("|")
        try:
            total_rows += int(p[2])
        except (ValueError, IndexError):
            pass

    print(f"{len(files)} source file(s) to aggregate, {total_rows:,} "
          f"availability rows between them.")
    print("Aggregating to (provider_id, technology, tract_geoid). Largest "
          "files first, so the estimate settles early rather than late.")
    print("Each file is an indexed read on source_file_id. A line per file.\n",
          flush=True)

    t0 = time.monotonic()
    rows_seen = 0
    for i, r in enumerate(files, 1):
        p = r.split("|")
        fid, fname = p[0], p[1]
        try:
            frows = int(p[2])
        except (ValueError, IndexError):
            frows = 0
        s0 = time.monotonic()
        before = int(psql_q("SELECT count(*) FROM provider_tract_tech_tbl")
                     or 0)
        psql("-qc", f"""
INSERT INTO provider_tract_tech_tbl (provider_id, technology, tract_geoid)
SELECT DISTINCT c.provider_id, a.technology, a.tract_geoid
FROM bdc_availability_tbl a
JOIN bdc_carrier_tbl c ON c.carrier_key = a.carrier_key
WHERE a.source_file_id = {int(fid)}
  AND a.technology IS NOT NULL
  AND c.provider_id IS NOT NULL
ON CONFLICT DO NOTHING""")
        after = int(psql_q("SELECT count(*) FROM provider_tract_tech_tbl")
                    or 0)
        el = time.monotonic() - s0
        psql("-qc",
             "INSERT INTO provider_tract_done_tbl (source_file_id, "
             f"rows_added, seconds) VALUES ({int(fid)}, {after - before}, "
             f"{el:.1f}) ON CONFLICT (source_file_id) DO NOTHING")
        rows_seen += frows
        tel = time.monotonic() - t0
        eta = ""
        if rows_seen and total_rows:
            rate = rows_seen / max(tel, 0.001)
            eta = (f", about {(total_rows - rows_seen) / rate / 60:.0f} min "
                   f"left")
        print(f"[{i}/{len(files)}] {fname[:46]:<46} {frows:>10,} rows read, "
              f"{after - before:>7,} pairs added, {el:>5.0f}s{eta}",
              flush=True)

    print(f"\naggregated in {(time.monotonic() - t0) / 60:.1f} minutes",
          flush=True)
    print(psql("-c", """
SELECT count(*) AS provider_tract_tech_rows,
       count(DISTINCT provider_id) AS providers,
       count(DISTINCT technology)  AS technologies,
       count(DISTINCT tract_geoid) AS tracts
FROM provider_tract_tech_tbl"""))
    print(f"Next:\n  python3 -u {script('step4_build.py')} distances")
    return 0


def cmd_distances(args):
    """Step 4: nearest own-carrier site per carrier, technology and tract."""
    require("provider_tract_tech_tbl",
            f"python3 -u {script('step4_build.py')} pairs")
    require("carrier_resolved_tbl",
            "Run geo/carrier_nodes/carrier_decisions.sql and "
            "load_decisions.py")

    print("Attaching ITDK domains to the provider-level pairs. This is the "
          "multiplication that had to come LAST: about sixteen domains per "
          "provider, applied to a few million aggregated pairs instead of "
          "to 519 million raw rows.\n", flush=True)

    t0 = time.monotonic()
    psql("-qc", """
DROP TABLE IF EXISTS step4_carrier_tract_tbl;
CREATE TABLE step4_carrier_tract_tbl AS
SELECT DISTINCT r.itdk_domain, p.technology, p.tract_geoid
FROM provider_tract_tech_tbl p
JOIN carrier_resolved_tbl r ON r.bdc_provider_id = p.provider_id
WHERE EXISTS (SELECT 1 FROM serving_site_tbl s
              WHERE s.carrier_domain = r.itdk_domain);
CREATE INDEX step4_ct_domain_idx ON step4_carrier_tract_tbl (itdk_domain);
CREATE INDEX step4_ct_tract_idx ON step4_carrier_tract_tbl (tract_geoid);""")
    print(f"  carrier, technology and tract triples: "
          f"{int(psql_q('SELECT count(*) FROM step4_carrier_tract_tbl')):,} "
          f"in {time.monotonic() - t0:.0f}s\n", flush=True)

    print("Measuring the distance from each tract centroid to that "
          "carrier's own nearest site, and to its second nearest, which "
          "step 5 needs. A carrier has few sites so no bounding box is "
          "used: the nearest is unrestricted and therefore correct rather "
          "than merely affordable.\n", flush=True)

    t1 = time.monotonic()
    psql("-qc", """
DROP TABLE IF EXISTS step4_tract_site_tbl;
CREATE TABLE step4_tract_site_tbl AS
SELECT ct.itdk_domain, ct.technology, ct.tract_geoid, t.state_usps,
       n.site_key, n.grade, n.city, n.km AS nearest_km,
       n2.site_key AS second_site_key, n2.km AS second_km
FROM step4_carrier_tract_tbl ct
JOIN census_tract_tbl t ON t.tract_geoid = ct.tract_geoid
LEFT JOIN LATERAL (
    SELECT s.site_key, s.grade, s.city,
           6371 * sqrt(pow(radians(s.lat - t.lat), 2) +
             pow(radians(((s.lon - t.lon + 540) -
               floor((s.lon - t.lon + 540) / 360) * 360) - 180)
                 * cos(radians(t.lat)), 2)) AS km
    FROM serving_site_tbl s
    WHERE s.carrier_domain = ct.itdk_domain
    ORDER BY pow(s.lat - t.lat, 2) +
             pow((s.lon - t.lon) * cos(radians(t.lat)), 2)
    LIMIT 1) n ON true
LEFT JOIN LATERAL (
    SELECT s.site_key,
           6371 * sqrt(pow(radians(s.lat - t.lat), 2) +
             pow(radians(((s.lon - t.lon + 540) -
               floor((s.lon - t.lon + 540) / 360) * 360) - 180)
                 * cos(radians(t.lat)), 2)) AS km
    FROM serving_site_tbl s
    WHERE s.carrier_domain = ct.itdk_domain
      AND s.site_key <> n.site_key
    ORDER BY pow(s.lat - t.lat, 2) +
             pow((s.lon - t.lon) * cos(radians(t.lat)), 2)
    LIMIT 1) n2 ON true;
CREATE INDEX step4_ts_domain_idx ON step4_tract_site_tbl (itdk_domain);
CREATE INDEX step4_ts_tract_idx ON step4_tract_site_tbl (tract_geoid);
COMMENT ON TABLE step4_tract_site_tbl IS
  'Step 4: for each ITDK carrier domain, technology code and census tract that carrier serves over that technology per the BDC, the distance from the tract centroid to that carrier''s own nearest serving site, and to its second nearest. Per carrier AND TECHNOLOGY because a carrier serves a tract over Copper from one facility and over fibre from another.';""")
    print(f"  measured in {(time.monotonic() - t1) / 60:.1f} minutes\n",
          flush=True)
    print(f"Next:\n  python3 -u {script('step4_build.py')} report")
    return 0


def cmd_report(args):
    require("step4_tract_site_tbl",
            f"python3 -u {script('step4_build.py')} distances")
    print("STEP 4, by technology. A tract is counted once per carrier and "
          "technology, which is the grain Boris asked for.\n")
    print(psql("-c", """
SELECT s.technology,
       coalesce(t.code_desc, 'UNKNOWN') AS technology_name,
       count(*)                         AS carrier_tract_pairs,
       count(DISTINCT s.tract_geoid)    AS tracts,
       count(DISTINCT s.itdk_domain)    AS carriers,
       round(avg(s.nearest_km)::numeric, 1) AS mean_km,
       round((percentile_cont(0.5) WITHIN GROUP
              (ORDER BY s.nearest_km))::numeric, 1) AS median_km
FROM step4_tract_site_tbl s
LEFT JOIN bdc_technology_tbl t ON t.technology = s.technology
GROUP BY 1, 2 ORDER BY count(*) DESC"""))

    print("Distance from the tract centroid to the serving carrier's own "
          "nearest site.\n")
    print(psql("-c", """
SELECT CASE WHEN nearest_km IS NULL THEN 'no site for this carrier'
            WHEN nearest_km <= 2   THEN 'a. within 2 km'
            WHEN nearest_km <= 10  THEN 'b. 2 to 10 km'
            WHEN nearest_km <= 25  THEN 'c. 10 to 25 km'
            WHEN nearest_km <= 50  THEN 'd. 25 to 50 km'
            ELSE                        'e. more than 50 km' END AS band,
       count(*) AS carrier_tract_pairs,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM step4_tract_site_tbl GROUP BY 1 ORDER BY 1"""))

    print("WHAT STEP 5 FACES. The ratio of second-nearest to nearest, for "
          "the same carrier. Under two, step 5's coverage test decides.\n")
    print(psql("-c", """
SELECT CASE WHEN second_km IS NULL THEN 'only one site for this carrier'
            WHEN second_km / nullif(nearest_km, 0) < 1.2
              THEN 'a. under 1.2, nearly tied'
            WHEN second_km / nullif(nearest_km, 0) < 2.0
              THEN 'b. 1.2 to 2.0, coverage test decides'
            ELSE 'c. over 2.0, nearest wins outright' END AS ratio_band,
       count(*) AS carrier_tract_pairs,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM step4_tract_site_tbl GROUP BY 1 ORDER BY 1"""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pairs",
                       help="aggregate availability to provider, technology "
                            "and tract, one line per source file")
    p.add_argument("--resume", action="store_true",
                   help="continue a part-finished build, re-reading nothing")
    p.set_defaults(func=cmd_pairs)

    d = sub.add_parser("distances", help="step 4 distances per carrier")
    d.set_defaults(func=cmd_distances)

    r = sub.add_parser("report", help="step 4 results by technology")
    r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
