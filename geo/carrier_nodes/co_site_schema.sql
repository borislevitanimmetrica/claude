-- co_site_schema.sql - building-level serving sites, with provenance that
-- cannot be omitted.
--
-- WHY THIS EXISTS, AND WHY PROVENANCE IS A NOT NULL COLUMN
--
-- Boris, 2026-11-18: "Be more thorough searching for coordinates of
-- headends/central offices. Google Gemini usually has the answer. Also
-- search for street address, which can be translated to coordinates.
-- Coordinates of a headend/CO may not always appear in public information."
--
-- He is right that more sources exist than the one we used. He is also
-- describing a route, search then translate, whose output is of a completely
-- different character from what clli_site_tbl holds. A rate centre
-- coordinate came from a published tariff geography. An address found by
-- searching and then geocoded is an INFERENCE about which building a carrier
-- operates, and an answer from an AI assistant is an assertion with no
-- citation at all until one is attached.
--
-- Standing order 1 is never to guess, and to label a guess at the moment it
-- is made rather than later. A table that stores latitude and longitude with
-- no column saying where they came from makes that order impossible to obey:
-- a day later nothing distinguishes a surveyed building from something an
-- LLM asserted. So source_kind, source_ref and precision are NOT NULL, and
-- verified defaults to false.
--
-- PRECISION IS THE COLUMN THAT MATTERS FOR STEP 4
--
-- Boris, 2026-11-18, correcting me: the four-block gap is in the Fabric
-- service-area mapping, not in the carrier nodes. That is right, and it
-- means node precision does NOT affect the gap test, which walks BDC block
-- coverage along the path.
--
-- What node precision does affect is the step 4 DISTANCE RANKING. Step 5
-- picks the nearest site unless another within twice the distance has
-- uninterrupted coverage, so the ordering of distances is the input to that
-- rule. In Manhattan, tract centroids sit roughly a kilometre apart, so
-- every distance measured from one rate-centre point is nearly equal and the
-- ordering is arbitrary. A 'rate_centre' row is therefore usable in rural
-- areas and close to useless in a dense metro, and the query has to be able
-- to tell which it has. Hence precision, and hence the view at the end that
-- reports the mix per carrier.

BEGIN;

CREATE TABLE IF NOT EXISTS co_site_tbl (
    site_key        bigserial PRIMARY KEY,

    -- WHAT THE SITE IS. clli8 is the switch or building level CLLI, eight
    -- characters, which identifies an actual building. clli6 is only the
    -- place and state, which is a rate centre and not a building. Both are
    -- nullable because a cable headend from an FCC registration has no CLLI
    -- at all.
    clli8           text,
    clli6           text,
    site_name       text,
    site_kind       text NOT NULL
                    CHECK (site_kind IN ('central_office', 'headend',
                                         'pop', 'rate_centre', 'unknown')),

    -- WHOSE IT IS. Carrier identity by the names this project already uses,
    -- so a site can be tied to the nodes that might sit in it. A Verizon
    -- node in Manhattan should be measured from a VERIZON building, not from
    -- whichever central office happens to be nearest the rate centre point.
    itdk_domain     text,
    ocn             text,
    carrier_name    text,

    -- WHERE IT IS.
    street_address  text,
    city            text,
    state_usps      text,
    zip             text,
    lat             double precision,
    lon             double precision,

    -- HOW GOOD THE LOCATION IS. Checked, not advisory.
    precision       text NOT NULL
                    CHECK (precision IN ('building', 'street', 'rate_centre',
                                         'city', 'none')),

    -- WHERE IT CAME FROM. All three NOT NULL. source_ref must be something
    -- a person can follow: a URL, a document number, a file name, a query.
    -- 'an AI said so' is not a source_ref; the citation the AI was repeating
    -- is.
    source_kind     text NOT NULL
                    CHECK (source_kind IN ('telcodata_switch',
                                           'lerg_rate_centre',
                                           'osm',
                                           'fcc_coals',
                                           'fcc_asr',
                                           'geocoded_address',
                                           'operator_published',
                                           'manual')),
    source_ref      text NOT NULL CHECK (source_ref <> ''),
    source_detail   text,

    -- HOW THE COORDINATES WERE DERIVED, when they were not published as
    -- coordinates. A geocoder that matched an approximate interpolated point
    -- is not the same as one that matched a parcel rooftop, and the match
    -- quality it reported is the only way to tell afterwards.
    geocoder        text,
    geocode_quality text,
    geocode_input   text,

    -- FALSE UNTIL CONFIRMED, by Boris or by a second independent source.
    -- Nothing downstream should rank distances using an unverified building
    -- claim without knowing that is what it is.
    verified        boolean NOT NULL DEFAULT false,
    verified_by     text,
    verified_at     timestamptz,

    note            text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE co_site_tbl IS
'Building-level serving sites: central offices, cable headends and POPs. Every row records where its location came from (source_kind, source_ref) and how precise it is (precision), because locations here are obtained by several routes of very different reliability, from published switch locations to an address found by searching and then geocoded. verified is false until confirmed by Boris or by a second independent source, and nothing should rank distances on an unverified building claim without knowing it is one.';

COMMENT ON COLUMN co_site_tbl.clli8 IS
'Eight character CLLI, which identifies a BUILDING. clli6 is place and state only, which is a rate centre and not a building.';

COMMENT ON COLUMN co_site_tbl.precision IS
'building: a specific structure. street: a street address geocoded to a block face. rate_centre: a tariff geography centroid, adequate rurally and close to useless in a dense metro. city: a municipality. Step 4 distance ranking is only meaningful between sites of comparable precision.';

COMMENT ON COLUMN co_site_tbl.source_ref IS
'Something a person can follow: a URL, an FCC document number, a file name, a query. An assertion from an AI assistant is not a source_ref; the citation it was repeating is.';

-- A site is identified by its CLLI when it has one, and otherwise by the
-- operator plus the address. Both are partial so that rows without a CLLI do
-- not all collide on NULL.
CREATE UNIQUE INDEX IF NOT EXISTS co_site_clli8_uk
    ON co_site_tbl (clli8) WHERE clli8 IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS co_site_addr_uk
    ON co_site_tbl (coalesce(ocn, ''), coalesce(carrier_name, ''),
                    coalesce(street_address, ''), coalesce(city, ''),
                    coalesce(state_usps, ''))
    WHERE clli8 IS NULL;

CREATE INDEX IF NOT EXISTS co_site_clli6_ix ON co_site_tbl (clli6)
    WHERE clli6 IS NOT NULL;
CREATE INDEX IF NOT EXISTS co_site_domain_ix ON co_site_tbl (itdk_domain)
    WHERE itdk_domain IS NOT NULL;

-- A BOUNDING BOX PREFILTER NEEDS lat AND lon INDEXED SEPARATELY.
-- Distance in SQL without PostGIS is a haversine expression, which cannot
-- use an index, so the only way to avoid a cross join at national scale is
-- to narrow by a latitude and longitude window first. Whether PostGIS is
-- installed here has NOT been checked, so nothing depends on it.
CREATE INDEX IF NOT EXISTS co_site_latlon_ix ON co_site_tbl (lat, lon)
    WHERE lat IS NOT NULL;

-- WHAT IS USABLE, AND AT WHAT PRECISION, PER CARRIER.
--
-- The point of this view is that it refuses to hide the difference. A
-- carrier with 40 building-level sites and a carrier with one rate-centre
-- point both have "coordinates", and step 4 would produce a number for
-- either; only one of those numbers means anything in a metro.
CREATE OR REPLACE VIEW co_site_readiness AS
SELECT coalesce(s.itdk_domain, '(no domain)')              AS itdk_domain,
       count(*)                                            AS sites,
       count(*) FILTER (WHERE s.lat IS NOT NULL)           AS with_coords,
       count(*) FILTER (WHERE s.precision = 'building')    AS building,
       count(*) FILTER (WHERE s.precision = 'street')      AS street,
       count(*) FILTER (WHERE s.precision = 'rate_centre') AS rate_centre,
       count(*) FILTER (WHERE s.precision = 'city')        AS city,
       count(*) FILTER (WHERE s.verified)                  AS verified,
       string_agg(DISTINCT s.source_kind, ', ' ORDER BY s.source_kind)
                                                           AS sources
FROM co_site_tbl s
GROUP BY 1
ORDER BY building DESC, sites DESC;

COMMENT ON VIEW co_site_readiness IS
'Per carrier, how many serving sites are known and at what precision. Deliberately separates building from rate_centre: step 4 will produce a distance from either, but only building-level precision makes the distance ordering meaningful in a dense metro.';

COMMIT;

\echo
\echo co_site_tbl ready. Nothing has been loaded into it.
\echo
\echo Every row requires source_kind, source_ref and precision. That is
\echo deliberate: coordinates reached by searching for an address and
\echo geocoding it are an inference about which building a carrier operates,
\echo and must stay distinguishable from a published switch location.
\echo
SELECT source_kind, count(*) FROM co_site_tbl GROUP BY 1 ORDER BY 1;
