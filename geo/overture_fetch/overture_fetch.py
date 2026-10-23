#!/usr/bin/env python3
"""
Fetch Overture Maps data (bbox, USA, or entire world) and save it locally.

Reads the public GeoParquet release directly from S3 with DuckDB. No account
or API key needed. The latest release is discovered automatically from the
Overture STAC catalog unless you pin one with --release.

Setup:
    pip install duckdb

Area selection (pick one):
    --bbox min_lon,min_lat,max_lon,max_lat    a single box (WGS84)
    --region usa                              50 states + DC + territories (approx. boxes)
    --region world                            no spatial filter at all

Output:
    name.parquet / .geojson / .csv   -> single file (fine for bbox / small areas)
    name  (no extension) or --partitioned
                                     -> directory of ~1 GB GeoParquet files
                                        (use this for usa / world)

Examples:
    # Massachusetts places that have BOTH a postcode and a website URL
    python overture_fetch.py --theme places --type place \
        --bbox -73.508,41.187,-69.858,42.887 \
        --require-postcode --require-website \
        --threads 16 -o out/ma_places.parquet

    # Small area, single file
    python overture_fetch.py --theme places --type place \
        --bbox -71.095,42.340,-71.050,42.370 -o boston_places.parquet

    # Entire USA, places, partitioned GeoParquet
    python overture_fetch.py --theme places --type place --region usa \
        --country US -o out/usa_places

    # Entire USA, buildings (large: hundreds of millions of rows)
    python overture_fetch.py --theme buildings --type building --region usa \
        -o out/usa_buildings --threads 8 --memory-limit 24GB

    # Entire world, places
    python overture_fetch.py --theme places --type place --region world \
        -o out/world_places

    # Entire world, every type in a theme: just loop
    for t in building building_part; do
        python overture_fetch.py --theme buildings --type $t --region world -o out/world_$t
    done

Notes:
  * The USA boxes also catch slivers of Canada, Mexico, Cuba, the Bahamas, etc.
    For exact US-only rows, add --country US (supported for places, addresses
    and divisions, which carry a country field). Other themes have no country
    field; clip them afterward against the US division_area polygon.
  * World-scale sizes are big. Rough order of magnitude: places tens of GB
    less, buildings hundreds of GB. Check free disk space first.
  * If you just want a raw mirror of the world, the AWS CLI is the fastest:
        aws s3 sync --no-sign-request --region us-west-2 \
            s3://overturemaps-us-west-2/release/<RELEASE>/theme=places/ ./places/
"""

import argparse
import json
import shutil
import sys
import urllib.request
from pathlib import Path

import duckdb

STAC_CATALOG = "https://stac.overturemaps.org/catalog.json"
S3_ROOT = "s3://overturemaps-us-west-2/release"

THEME_TYPES = {
    "addresses": ["address"],
    "base": ["bathymetry", "infrastructure", "land", "land_cover", "land_use", "water"],
    "buildings": ["building", "building_part"],
    "divisions": ["division", "division_area", "division_boundary"],
    "places": ["place"],
    "transportation": ["connector", "segment"],
}

# Approximate boxes (min_lon, min_lat, max_lon, max_lat). The Aleutians cross
# the antimeridian, hence two Alaska boxes.
USA_BOXES = [
    (-124.9, 24.3, -66.9, 49.5),     # contiguous US
    (-179.3, 51.0, -129.9, 71.5),    # Alaska (east of antimeridian)
    (172.0, 51.0, 180.0, 53.6),      # Alaska (western Aleutians)
    (-160.5, 18.8, -154.7, 22.3),    # Hawaii
    (-67.5, 17.8, -64.5, 18.6),      # Puerto Rico + USVI
    (144.5, 13.2, 146.2, 20.6),      # Guam + Northern Marianas
    (-171.2, -14.6, -168.0, -14.1),  # American Samoa
]

# Where each theme/type keeps its ISO country code (None = no such field)
COUNTRY_EXPR = {
    ("places", "place"): "addresses[1].country",
    ("addresses", "address"): "country",
    ("divisions", "division"): "country",
    ("divisions", "division_area"): "country",
    ("divisions", "division_boundary"): None,
}


# "Has a usable postcode": places keep addresses as a list of structs, so any
# address entry with a non-blank postcode counts; the addresses theme has a
# flat postcode column.
POSTCODE_EXPR = {
    ("places", "place"):
        "len(list_filter(addresses, a -> a.postcode IS NOT NULL AND trim(a.postcode) <> '')) > 0",
    ("addresses", "address"):
        "postcode IS NOT NULL AND trim(postcode) <> ''",
}

# "Has a website": places.websites is a list of URL strings.
WEBSITE_EXPR = {
    ("places", "place"):
        "len(list_filter(websites, w -> w IS NOT NULL AND trim(w) <> '')) > 0",
}


def latest_release() -> str:
    with urllib.request.urlopen(STAC_CATALOG, timeout=30) as resp:
        catalog = json.load(resp)
    release = catalog.get("latest")
    if not release:
        sys.exit("Could not determine latest release from STAC catalog; use --release.")
    return release


def parse_bbox(text: str):
    try:
        xmin, ymin, xmax, ymax = (float(p) for p in text.split(","))
    except ValueError:
        sys.exit("--bbox must be four numbers: min_lon,min_lat,max_lon,max_lat")
    if not (-180 <= xmin < xmax <= 180 and -90 <= ymin < ymax <= 90):
        sys.exit("--bbox out of range or min >= max")
    return (xmin, ymin, xmax, ymax)


def box_clause(b):
    xmin, ymin, xmax, ymax = b
    return (f"(bbox.xmin <= {xmax} AND bbox.xmax >= {xmin} "
            f"AND bbox.ymin <= {ymax} AND bbox.ymax >= {ymin})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--theme", required=True, choices=sorted(THEME_TYPES))
    ap.add_argument("--type", required=True, dest="type_", help="Feature type within the theme")
    area = ap.add_mutually_exclusive_group(required=True)
    area.add_argument("--bbox", help="min_lon,min_lat,max_lon,max_lat")
    area.add_argument("--region", choices=["usa", "world"])
    ap.add_argument("--country", help="ISO 3166-1 alpha-2 code, e.g. US (places/addresses/divisions only)")
    ap.add_argument("--require-postcode", action="store_true",
                    help="Keep only features with a non-empty postcode (places, addresses)")
    ap.add_argument("--require-website", action="store_true",
                    help="Keep only features with at least one non-empty website URL (places)")
    ap.add_argument("--release", help="Release tag, e.g. 2025-01-22.0 (default: latest)")
    ap.add_argument("--where", help="Extra SQL filter, e.g. \"categories.primary = 'cafe'\"")
    ap.add_argument("--limit", type=int, help="Max number of rows")
    ap.add_argument("-o", "--output", required=True,
                    help=".parquet/.geojson/.csv = single file; no extension = partitioned directory")
    ap.add_argument("--partitioned", action="store_true",
                    help="Force directory output of ~1 GB GeoParquet files")
    ap.add_argument("--file-size", default="1GB", help="Target file size when partitioned (default 1GB)")
    ap.add_argument("--threads", type=int, help="DuckDB threads (default: all cores)")
    ap.add_argument("--memory-limit", help="DuckDB memory limit, e.g. 16GB")
    # argparse mistakes a value like "-73.5,41.1,..." for an option flag.
    # Glue "--bbox VALUE" into "--bbox=VALUE" so negative longitudes work.
    argv, i = [], 1
    raw = sys.argv
    while i < len(raw):
        if raw[i] in ("--bbox", "--where") and i + 1 < len(raw):
            argv.append(f"{raw[i]}={raw[i + 1]}")
            i += 2
        else:
            argv.append(raw[i])
            i += 1
    args = ap.parse_args(argv)

    if args.type_ not in THEME_TYPES[args.theme]:
        sys.exit(f"Type '{args.type_}' not in theme '{args.theme}'. "
                 f"Valid: {', '.join(THEME_TYPES[args.theme])}")

    # --- area filter ---
    if args.bbox:
        boxes = [parse_bbox(args.bbox)]
    elif args.region == "usa":
        boxes = USA_BOXES
    else:
        boxes = []  # world: no spatial filter

    conditions = []
    if boxes:
        conditions.append("(" + " OR ".join(box_clause(b) for b in boxes) + ")")

    if args.country:
        key = (args.theme, args.type_)
        expr = COUNTRY_EXPR.get(key)
        if expr is None:
            sys.exit(f"--country isn't supported for {args.theme}/{args.type_} (no country field). "
                     "Use --region/--bbox and clip afterward.")
        code = args.country.upper()
        if not (len(code) == 2 and code.isalpha()):
            sys.exit("--country must be a 2-letter ISO code")
        conditions.append(f"{expr} = '{code}'")

    key = (args.theme, args.type_)
    if args.require_postcode:
        expr = POSTCODE_EXPR.get(key)
        if expr is None:
            sys.exit(f"--require-postcode isn't supported for {args.theme}/{args.type_}")
        conditions.append(f"({expr})")
    if args.require_website:
        expr = WEBSITE_EXPR.get(key)
        if expr is None:
            sys.exit(f"--require-website isn't supported for {args.theme}/{args.type_} (places only)")
        conditions.append(f"({expr})")

    if args.where:
        conditions.append(f"({args.where})")

    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    limit = f"LIMIT {int(args.limit)}" if args.limit else ""

    # --- output mode ---
    out = Path(args.output)
    ext = out.suffix.lower()
    partitioned = args.partitioned or ext == ""
    if not partitioned and ext not in {".parquet", ".geojson", ".csv"}:
        sys.exit("Output extension must be .parquet, .geojson or .csv (or none for a directory)")
    if partitioned and ext not in {"", ".parquet"}:
        sys.exit("Partitioned output must be a directory name (no .geojson/.csv extension)")
    if partitioned and out.suffix:
        out = out.with_suffix("")  # directory, not a .parquet-named dir

    if args.region == "world" and not partitioned:
        print("WARNING: world-scale data as a single file is rarely a good idea; "
              "consider a directory output.", file=sys.stderr)

    if out.exists():
        shutil.rmtree(out) if out.is_dir() else out.unlink()
    out.parent.mkdir(parents=True, exist_ok=True)

    release = args.release or latest_release()
    source = f"{S3_ROOT}/{release}/theme={args.theme}/type={args.type_}/*"
    area_desc = args.bbox or args.region
    print(f"Release : {release}\nSource  : {source}\nArea    : {area_desc}"
          f"{'  country=' + args.country.upper() if args.country else ''}\nOutput  : {out}"
          f"{' (partitioned)' if partitioned else ''}")

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("INSTALL spatial; LOAD spatial;")
    con.execute("SET s3_region='us-west-2';")
    con.execute("SET preserve_insertion_order=false;")  # big memory saver for large exports
    if args.threads:
        con.execute(f"SET threads={int(args.threads)};")
    if args.memory_limit:
        con.execute(f"SET memory_limit='{args.memory_limit}';")

    select = f"SELECT * FROM read_parquet('{source}', hive_partitioning=1) {where} {limit}"

    if partitioned:
        copy_opts = f"(FORMAT PARQUET, COMPRESSION ZSTD, FILE_SIZE_BYTES '{args.file_size}')"
    elif ext == ".parquet":
        copy_opts = "(FORMAT PARQUET, COMPRESSION ZSTD)"
    elif ext == ".geojson":
        copy_opts = "(FORMAT GDAL, DRIVER 'GeoJSON')"
    else:  # csv: geometry as WKT; nested columns are written as text
        select = f"SELECT * REPLACE (ST_AsText(geometry) AS geometry) FROM ({select})"
        copy_opts = "(FORMAT CSV, HEADER)"

    print("Querying... (large areas can take hours; progress isn't shown by DuckDB's COPY)")
    con.execute(f"COPY ({select}) TO '{out}' {copy_opts}")

    if out.is_dir():
        files = list(out.glob("*.parquet"))
        total = sum(f.stat().st_size for f in files) / 1e9
        print(f"Done: {len(files)} files, {total:.2f} GB in {out}/")
    else:
        print(f"Done: {out} ({out.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()