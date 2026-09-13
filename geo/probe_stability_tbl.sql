-- probe_stability_tbl.sql
-- Repeated observations of the SAME addresses over time, so that drift in
-- geolocation answers becomes a measured quantity instead of an anecdote.
--
-- WHY THIS TABLE EXISTS
--
-- 172.56.54.0/24 was probed at /28 twice. The first run returned three Los
-- Angeles ZIPs across its sixteen /28s. A later run returned Dallas 75237 for all
-- sixteen, twice in succession. Nothing in the pipeline noticed, and nothing could
-- have: ran_at records when a range was measured but no second measurement is ever
-- taken, so an answer that silently stops being true stays in the output forever.
--
-- The operative question is therefore not only how finely a carrier resolves but
-- how long an answer stays valid. That is what this table measures.
--
-- WHY THE SAME ADDRESS EVERY ROUND
--
-- This is the whole design, and getting it wrong makes the data uninterpretable.
-- If each round picked a fresh random address inside the block, a changed city
-- could mean either that the block moved or that two hosts inside it sit in
-- different places, and the two are indistinguishable afterwards. Holding
-- probe_ip fixed makes any change unambiguously drift over time.
--
-- WHY A CONTROL COHORT IS REQUIRED, NOT OPTIONAL
--
-- Mobile churn on its own proves nothing, because an ip-api wide data revision
-- would move mobile and wireline alike. Running an identical schedule against
-- Comcast and Charter is what separates carrier behaviour from vendor data
-- refresh. A cohort without a control is not evidence.
--
-- Contains NO backslashes so it survives copy/paste.


CREATE TABLE IF NOT EXISTS probe_stability_tbl (
    id             bigserial   PRIMARY KEY,

    -- A label grouping one schedule of observations, for example
    -- tmobile-as21928 or comcast-as7922. Cohorts are compared against each other.
    cohort         text        NOT NULL,

    -- The sub-block sampled, and the address held fixed inside it.
    network        cidr        NOT NULL,
    probe_ip       inet        NOT NULL,

    round          int         NOT NULL,
    observed_at    timestamptz NOT NULL DEFAULT now(),

    status         text,
    country        text,
    country_code   text,
    city           text,
    state_code     text,
    zip            text,
    isp            text,
    org            text,
    as_text        text,

    -- ip-api's OWN mobile flag, requested explicitly. It is not part of ip-api's
    -- default field set, so nothing in this project captured it before. It is
    -- recorded here separately from any keyword judgement so the two can be
    -- compared rather than conflated.
    mobile_ipapi   boolean,

    err            text,

    CONSTRAINT probe_stability_uniq UNIQUE (cohort, probe_ip, round)
);

CREATE INDEX IF NOT EXISTS probe_stability_cohort_idx
    ON probe_stability_tbl (cohort, probe_ip, round);

COMMENT ON TABLE probe_stability_tbl IS
    'Repeated ip-api observations of fixed addresses, written by probe_range_split -repeat. Measures how long a geolocation answer stays true. Never read by the targeting path.';


-- ---------------------------------------------------------------------------
-- 1. CHURN PER COHORT. The headline number.
--
-- An address counts as churned when it returned more than one distinct
-- city/state over the rounds. ZIP churn is reported separately because ZIP can
-- move while city holds, which matters: the DMA tier resolves through city and
-- survives ZIP churn, while the ZIP tier does not.
-- ---------------------------------------------------------------------------

WITH per_addr AS (
    SELECT cohort,
           probe_ip,
           count(DISTINCT city || '|' || coalesce(state_code, '')) AS distinct_places,
           count(DISTINCT zip) FILTER (WHERE zip IS NOT NULL AND zip <> '') AS distinct_zips,
           count(*) AS rounds_seen
    FROM probe_stability_tbl
    WHERE status = 'success'
    GROUP BY cohort, probe_ip
)
SELECT cohort,
       count(*)                                                   AS addresses,
       min(rounds_seen)                                           AS min_rounds,
       max(rounds_seen)                                           AS max_rounds,
       count(*) FILTER (WHERE distinct_places > 1)                 AS city_churned,
       round(100.0 * count(*) FILTER (WHERE distinct_places > 1) / count(*), 1) AS city_churn_pct,
       count(*) FILTER (WHERE distinct_zips > 1)                    AS zip_churned,
       round(100.0 * count(*) FILTER (WHERE distinct_zips > 1) / count(*), 1)   AS zip_churn_pct
FROM per_addr
GROUP BY cohort
ORDER BY cohort;


-- ---------------------------------------------------------------------------
-- 2. HOW FAST. The shortest interval over which any change was observed.
--
-- This is the number that decides whether a daily probe cycle is sufficient. If
-- the fastest observed change is longer than the cycle, the cycle keeps up. If it
-- is shorter, the output carries stale answers no matter how fast the cycle runs.
-- ---------------------------------------------------------------------------

WITH ordered AS (
    SELECT cohort, probe_ip, observed_at, city, state_code, zip,
           lag(city)        OVER w AS prev_city,
           lag(state_code)  OVER w AS prev_state,
           lag(zip)         OVER w AS prev_zip,
           lag(observed_at) OVER w AS prev_at
    FROM probe_stability_tbl
    WHERE status = 'success'
    WINDOW w AS (PARTITION BY cohort, probe_ip ORDER BY round)
)
SELECT cohort,
       count(*) FILTER (WHERE city IS DISTINCT FROM prev_city
                          OR state_code IS DISTINCT FROM prev_state) AS city_changes,
       min(observed_at - prev_at) FILTER (WHERE city IS DISTINCT FROM prev_city
                          OR state_code IS DISTINCT FROM prev_state) AS fastest_city_change,
       count(*) FILTER (WHERE zip IS DISTINCT FROM prev_zip)         AS zip_changes,
       min(observed_at - prev_at) FILTER (WHERE zip IS DISTINCT FROM prev_zip) AS fastest_zip_change
FROM ordered
WHERE prev_at IS NOT NULL
GROUP BY cohort
ORDER BY cohort;


-- ---------------------------------------------------------------------------
-- 3. THE ACTUAL CHANGES, for reading rather than aggregating.
-- ---------------------------------------------------------------------------

WITH ordered AS (
    SELECT cohort, probe_ip, network, round, observed_at, city, state_code, zip, isp,
           lag(city)        OVER w AS prev_city,
           lag(state_code)  OVER w AS prev_state,
           lag(zip)         OVER w AS prev_zip,
           lag(observed_at) OVER w AS prev_at
    FROM probe_stability_tbl
    WHERE status = 'success'
    WINDOW w AS (PARTITION BY cohort, probe_ip ORDER BY round)
)
SELECT cohort, probe_ip, network, round, observed_at - prev_at AS elapsed,
       coalesce(prev_city, '?') || ', ' || coalesce(prev_state, '?') || ' ' || coalesce(prev_zip, '') AS was,
       city || ', ' || coalesce(state_code, '?') || ' ' || coalesce(zip, '') AS now_is,
       isp
FROM ordered
WHERE prev_at IS NOT NULL
  AND (city IS DISTINCT FROM prev_city
       OR state_code IS DISTINCT FROM prev_state
       OR zip IS DISTINCT FROM prev_zip)
ORDER BY cohort, probe_ip, round
LIMIT 200;


-- ---------------------------------------------------------------------------
-- 4. DOES ip-api's OWN mobile FLAG AGREE WITH THE KEYWORD RULE.
--
-- The pipeline sets likely_mobile_cgnat from a keyword match on isp and org, and
-- has never consulted ip-api's mobile field, which is not in ip-api's default
-- field set. This lists the isp strings where the two would disagree, which is the
-- set worth reading before relying on either alone to gate ZIP-level output.
-- ---------------------------------------------------------------------------

SELECT isp,
       count(*)                                        AS observations,
       bool_or(mobile_ipapi)                            AS ipapi_ever_says_mobile,
       bool_and(mobile_ipapi)                           AS ipapi_always_says_mobile,
       (lower(isp) LIKE '%wireless%'
        OR lower(isp) LIKE '%cellular%'
        OR lower(isp) LIKE '%mobile%'
        OR lower(isp) LIKE '%mobility%'
        OR lower(isp) LIKE '%sprint%'
        OR lower(isp) LIKE '%metropcs%'
        OR lower(isp) LIKE '%boost%'
        OR lower(isp) LIKE '%pcs%')                     AS keyword_says_mobile
FROM probe_stability_tbl
WHERE status = 'success' AND isp IS NOT NULL
GROUP BY isp
ORDER BY observations DESC
LIMIT 50;
