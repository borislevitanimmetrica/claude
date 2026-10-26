#!/usr/bin/env python3
"""
Load Foursquare OS Places (United States) into fsq_places_usa.

Foursquare's schema is FLAT, unlike Overture's nested structs, so this is one
step rather than overture_fetch.py + parquet_to_pg.py. The rows stream straight
into PostgreSQL over DuckDB's binary COPY protocol.

ACCESS IS GATED. This is not a code problem and no flag works around it.

    The public S3 bucket s3://fsq-os-places-us-east-1 no longer holds the data.
    As of 2026-10-26 it contains LICENSE.txt and NOTICE.txt and nothing else,
    so the anonymous DuckDB-over-S3 route that overture_fetch.py uses is gone.

    The data moved to Hugging Face as a GATED dataset. Listing the files works
    anonymously; downloading one returns HTTP 401. You need a free Hugging Face
    account, acceptance of the dataset terms (gating is "auto", so approval is
    immediate), and a read token.

    The licence did NOT change. The data is still Apache 2.0 and still free for
    commercial use. Only distribution is behind a login.

Setup:
    pip install duckdb
    Create a token at https://huggingface.co/settings/tokens (role: read)
    Accept the terms at https://huggingface.co/datasets/foursquare/fsq-os-places
    export HF_TOKEN=hf_...

Two ways to read the parquet:

  --input hf://datasets/foursquare/fsq-os-places/release/dt=2026-10-15/places/parquet/*.parquet
        Streams from Hugging Face. Needs HF_TOKEN. DuckDB fetches only the row
        groups it needs, so the US filter does not cost the full 10.79 GB.

  --input /path/to/local/*.parquet
        Whatever you downloaded yourself. No token needed at this point.

Discover the current release without a token (listing is not gated):
    python3 fsq_fetch.py releases

Workflow:
    psql -v ON_ERROR_STOP=1 -f create_table_fsq_places_usa.sql
    python3 fsq_fetch.py load --input hf://... --release 2026-10-15
    python3 fsq_fetch.py verify

Then the SHARED chain, which needs no Foursquare-specific code:
    python3 ../overture_fetch/ovt_resolve_hosts.py resolve      --table fsq_places_usa
    python3 ../overture_fetch/ovt_resolve_hosts.py rdap         --table fsq_places_usa
    python3 ../overture_fetch/ovt_resolve_hosts.py registrants  --table fsq_places_usa
    python3 ../overture_fetch/ovt_resolve_hosts.py overture-zip --table fsq_places_usa
    python3 ../overture_fetch/ovt_resolve_hosts.py onpremises   --table fsq_places_usa

Attribution, required by the Apache 2.0 NOTICE that ships with the data:
    Contains information from Foursquare OS Places, (c) 2025 Foursquare Labs,
    Inc., licensed under the Apache License, Version 2.0.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HF_REPO = "foursquare/fsq-os-places"
HF_TREE = "https://huggingface.co/api/datasets/{repo}/tree/main/{path}"

# The 24 columns Foursquare publishes, in the order create_table_fsq_places_usa.sql
# declares them. Named explicitly rather than taken as "*" so that a column added
# or reordered in a future release cannot silently shift values into the wrong
# column, which is the same reason the ClickHouse loader lists them out.
FSQ_COLUMNS = [
    "fsq_place_id", "name", "latitude", "longitude", "address", "locality",
    "region", "postcode", "admin_region", "post_town", "po_box", "country",
    "website", "tel", "email", "facebook_id", "instagram", "twitter",
    "fsq_category_ids", "fsq_category_labels", "date_created",
    "date_refreshed", "date_closed",
]

# These two are parquet LISTs, not strings. Inserting a DuckDB list straight
# into a PostgreSQL text column fails, so they are rendered as JSON text. That
# keeps multiplicity ("a place has several categories") readable and queryable
# with the json operators, instead of flattening to a lossy comma string.
FSQ_ARRAY_COLUMNS = {"fsq_category_ids", "fsq_category_labels"}


def source_expr(col: str) -> str:
    if col in FSQ_ARRAY_COLUMNS:
        return f"to_json({col})::VARCHAR AS {col}"
    return col


def lit(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


def psql_dsn() -> str:
    """Build a libpq DSN from the connection psql itself uses.

    DuckDB's postgres extension bundles its own libpq and so does not inherit
    psql's compiled-in defaults, such as a distro socket directory. Asking psql
    what it actually connected to avoids guessing. Same approach as
    parquet_to_pg.py, deliberately, so both loaders land in the same database.
    """
    sql = ("select current_database(), current_user, current_setting('port'), "
           "coalesce(host(inet_server_addr()), ''), "
           "current_setting('unix_socket_directories')")
    try:
        out = subprocess.run(["psql", "-X", "-qtA", "-F", "|", "-c", sql],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or exc
        sys.exit(f"Could not get connection details from psql: {detail}")
    db, user, port, tcp_host, sock_dirs = out.split("|", 4)
    host = os.environ.get("PGHOST") or tcp_host or sock_dirs.split(",")[0].strip()
    parts = {"dbname": db, "user": user, "port": port, "host": host}
    return " ".join(f"{k}={lit(v)}" for k, v in parts.items())


def run_psql(sql: str) -> str:
    try:
        return subprocess.run(["psql", "-X", "-qtA", "-F", "|", "-v", "ON_ERROR_STOP=1",
                               "-c", sql],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or exc
        sys.exit(f"psql failed: {detail}")


def hf_list(path: str):
    """List a directory in the HF repo. Listing is NOT gated, downloading is."""
    url = HF_TREE.format(repo=HF_REPO, path=path)
    req = urllib.request.Request(url)
    token = os.environ.get("HF_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as exc:
        sys.exit(f"Hugging Face listing failed for {path}: HTTP {exc.code} {exc.reason}")
    except OSError as exc:
        sys.exit(f"Hugging Face listing failed for {path}: {exc}")


def cmd_releases(args):
    """Print the available releases and the size of each places parquet set."""
    entries = hf_list("release")
    dts = sorted(e["path"].split("dt=")[-1] for e in entries
                 if e.get("type") == "directory" and "dt=" in e.get("path", ""))
    if not dts:
        sys.exit("No releases found. The repository layout may have changed.")
    print(f"{len(dts)} releases, newest last:")
    for dt in dts:
        print(f"  {dt}")
    newest = dts[-1]
    files = hf_list(f"release/dt={newest}/places/parquet")
    pq = [f for f in files if f.get("path", "").endswith(".parquet")]
    total = sum(f.get("size", 0) for f in pq)
    print(f"\nNewest release {newest}: {len(pq)} parquet files, "
          f"{total / 1024 / 1024 / 1024:.2f} GB")
    print("\nTo load it:")
    print(f"  python3 {os.path.basename(sys.argv[0])} load --release {newest} \\")
    print(f"    --input 'hf://datasets/{HF_REPO}/release/dt={newest}/places/parquet/*.parquet'")
    if not os.environ.get("HF_TOKEN"):
        print("\nHF_TOKEN is not set. Listing works without it; downloading does not.")


def build_select(args) -> str:
    """The SELECT that reshapes Foursquare's flat columns for the shared chain.

    Two synthesised columns carry the whole integration:

    websites   the bare URL. ovt_resolve_hosts.py uses a text value that does
               not start with "[" as-is, so no JSON array wrapper is needed.

    addresses  Overture's JSON shape, because cmd_overture_zip matches
               '"postcode":"12345"', '"freeform":"..."', '"locality":"..."' and
               '"region":"..."' against the address text. to_json on a struct
               does the quoting and escaping, so an apostrophe or a quote in a
               street name cannot produce malformed JSON.

    country is forced to 'US' in the emitted address because the WHERE clause
    has already restricted to US rows, and the ZIP_AT_END_RE fallback in the
    chain recognises 'US' explicitly.
    """
    # NOTE: this SQL runs in DuckDB, not PostgreSQL, so it is trim() and not
    # btrim(). The verify step's queries run in psql and do use btrim.
    src = ", ".join(source_expr(c) for c in FSQ_COLUMNS)
    where = ["country = 'US'"]
    if not args.include_closed:
        where.append("date_closed IS NULL")
    if args.require_website:
        where.append("website IS NOT NULL AND trim(website) <> ''")
    if args.require_postcode:
        where.append("postcode IS NOT NULL AND trim(postcode) <> ''")
    if args.states:
        states = ", ".join(lit(s.strip().upper()) for s in args.states.split(",") if s.strip())
        where.append(f"upper(trim(region)) IN ({states})")
    if args.zip_prefix:
        where.append(f"trim(postcode) LIKE {lit(args.zip_prefix + '%')}")

    return f"""
SELECT
    {src},
    {lit(args.release)} AS dt,
    nullif(trim(website), '') AS websites,
    to_json({{
        freeform: nullif(trim(address),  ''),
        locality: nullif(trim(locality), ''),
        postcode: nullif(trim(postcode), ''),
        region:   nullif(trim(region),   ''),
        country:  'US'
    }})::VARCHAR AS addresses
FROM read_parquet({lit(args.input)})
WHERE {' AND '.join(where)}
"""


def cmd_load(args):
    try:
        import duckdb
    except ImportError:
        sys.exit("duckdb not installed. Run: pip install duckdb")

    if args.input.startswith("hf://") and not os.environ.get("HF_TOKEN"):
        sys.exit("HF_TOKEN is not set, and hf:// downloads are gated (HTTP 401).\n"
                 "Create a read token at https://huggingface.co/settings/tokens, accept the\n"
                 "terms at https://huggingface.co/datasets/foursquare/fsq-os-places, then\n"
                 "export HF_TOKEN=... . Or download the parquet yourself and pass a local path.")

    # A dry run reads parquet only, so it must not require a database. Checking
    # the table first would make --dry-run useless for validating a release
    # before the schema exists.
    if not args.dry_run:
        cols = run_psql("select column_name from information_schema.columns "
                        "where table_schema = 'public' and table_name = 'fsq_places_usa'")
        if not cols:
            sys.exit("Table public.fsq_places_usa not found. Run "
                     "create_table_fsq_places_usa.sql first.")

    con = duckdb.connect()
    con.execute(f"SET threads TO {args.threads}")
    con.execute(f"SET memory_limit = '{args.memory_limit}'")
    con.execute("INSTALL postgres; LOAD postgres;")
    if args.input.startswith("hf://"):
        con.execute("INSTALL httpfs; LOAD httpfs;")
        con.execute("CREATE OR REPLACE SECRET hf_token (TYPE huggingface, TOKEN "
                    f"{lit(os.environ['HF_TOKEN'])})")

    select = build_select(args)

    if args.dry_run:
        print("Counting matching rows (no write) ...", flush=True)
        n = con.execute(f"SELECT count(*) FROM ({select}) s").fetchone()[0]
        print(f"{n:,} rows would be loaded.")
        print("\nSample of the two synthesised columns:")
        for w, a in con.execute(f"SELECT websites, addresses FROM ({select}) s "
                                f"WHERE websites IS NOT NULL LIMIT 3").fetchall():
            print(f"  websites : {w}")
            print(f"  addresses: {a}")
        return

    con.execute(f"ATTACH {lit(psql_dsn())} AS pg (TYPE postgres)")
    target = "pg.public.fsq_places_usa"
    if args.truncate:
        print("Truncating fsq_places_usa ...", flush=True)
        con.execute(f"DELETE FROM {target}")

    # The column list is explicit on BOTH sides so the load cannot be misaligned
    # by a schema change at either end.
    dest = ", ".join(FSQ_COLUMNS + ["dt", "websites", "addresses"])
    print(f"Loading into fsq_places_usa from {args.input} ...", flush=True)
    con.execute(f"INSERT INTO {target} ({dest}) {select}")
    print("Loaded. Now run `verify`, then the ovt_resolve_hosts.py chain "
          "with --table fsq_places_usa.")


def cmd_verify(args):
    """Check the load landed, and that the synthesised columns are usable.

    The last two checks are the ones that matter: they apply the SAME regexes
    cmd_overture_zip uses, so a pass here means the ZIP step will work on this
    table rather than silently setting overture_zip_source = 'none' everywhere.
    """
    print(run_psql("""
SELECT count(*)                                                      AS rows,
       count(DISTINCT fsq_place_id)                                   AS distinct_places,
       count(*) FILTER (WHERE websites IS NOT NULL)                    AS with_website,
       count(*) FILTER (WHERE postcode IS NOT NULL)                    AS with_postcode,
       count(DISTINCT left(lpad(btrim(postcode),5,'0'),5))             AS distinct_zips
FROM fsq_places_usa"""))
    print("\nDo the chain's ZIP regexes match the synthesised addresses?")
    print(run_psql(r"""
SELECT count(*) AS rows_with_address,
       count(*) FILTER (WHERE substring(addresses from '"postcode"\s*:\s*"([0-9]{5})') IS NOT NULL)
           AS postcode_regex_matches,
       count(*) FILTER (WHERE substring(addresses from '"freeform"\s*:\s*"([^"]*)"') IS NOT NULL)
           AS freeform_regex_matches,
       count(*) FILTER (WHERE substring(addresses from '"locality"\s*:\s*"([^"]*)"') IS NOT NULL)
           AS locality_regex_matches,
       count(*) FILTER (WHERE substring(addresses from '"region"\s*:\s*"([^"]*)"') IS NOT NULL)
           AS region_regex_matches
FROM fsq_places_usa WHERE addresses IS NOT NULL"""))


def main():
    p = argparse.ArgumentParser(
        description="Load Foursquare OS Places (USA) into fsq_places_usa.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Access is gated: see the module docstring. HF_TOKEN is required "
               "for hf:// input, not for a local path.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("releases", help="list available releases (no token needed)")

    ld = sub.add_parser("load", help="load US rows into fsq_places_usa")
    ld.add_argument("--input", required=True,
                    help="parquet glob: an hf:// URL or a local path")
    ld.add_argument("--release", required=True,
                    help="release date, e.g. 2026-10-15; recorded in the dt column")
    ld.add_argument("--states", help="comma-separated region codes, e.g. MA,NH,VT")
    ld.add_argument("--zip-prefix", help="only postcodes starting with this, e.g. 021")
    ld.add_argument("--require-website", action="store_true",
                    help="skip rows with no website; they can never become landmarks")
    ld.add_argument("--require-postcode", action="store_true",
                    help="skip rows with no postcode")
    ld.add_argument("--include-closed", action="store_true",
                    help="keep rows with date_closed set (excluded by default)")
    ld.add_argument("--truncate", action="store_true", help="empty the table first")
    ld.add_argument("--dry-run", action="store_true",
                    help="count matching rows and show the synthesised columns")
    ld.add_argument("--threads", type=int, default=8)
    ld.add_argument("--memory-limit", default="8GB")

    sub.add_parser("verify", help="row counts and a check of the synthesised columns")

    args = p.parse_args()
    {"releases": cmd_releases, "load": cmd_load, "verify": cmd_verify}[args.cmd](args)


if __name__ == "__main__":
    main()
