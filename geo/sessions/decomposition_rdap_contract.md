# Decomposition and RDAP: the verified contract

Written 2026-11-09 after I stated two things about this that were false. Boris
corrected both. This file records what the code actually does, with the line
references, so the next instance does not repeat it.

Everything under "Verified" was read out of the source in this session.
Anything not verified is labelled.

## What I got wrong

**Claim 1, FALSE.** I said a candidate retired by the RDAP fill "inherits the
enclosing allocation's registrant, not the most specific one", and framed it as
a limitation of how `apply_splits` consumes the cache.

`apply_splits/cmd/main.go` takes the NARROWEST containing allocation:

    LEFT JOIN LATERAL (
      SELECT r.registrant, true AS found FROM rdap_registrant_tbl r
      WHERE r.start_ip <= host(network(c.network))::inet
        AND r.end_ip >= host(broadcast(c.network))::inet
      ORDER BY (r.end_ip - r.start_ip) LIMIT 1) rd ON true

The comment immediately above it states the intent outright: "Under RDAP the
covering allocation is the most specific one that wholly contains the range, so
an ARIN reassignment inside a larger allocation takes precedence over its
parent."

This is a project-wide convention, not a local choice:

- `apply_splits/cmd/main.go`, the lateral join above
- `geo/landmark2zip_tbl.sql` line 327, same `ORDER BY (r.end_ip - r.start_ip)
  LIMIT 1`, applied to a single address
- `geo/landmark_carrier_node.sql` line 403, which names it as the convention:
  "the narrowest allocation is the one that describes the address"

I contradicted a recorded design decision without reading it. That is standing
order 5 as well as standing order 1.

**Claim 2, FALSE by omission.** I implied decomposed subranges could inherit a
parent's identification. They cannot, because the parent ceases to exist.

## Verified: decomposition deletes the parent

`decompose()` in `apply_splits/cmd/main.go`, one transaction:

1. INSERT the children at `-unit` (default 25) with `source = 'routeviews'`,
   `ON CONFLICT (network) DO NOTHING`.
2. If `inserted == 0`, return WITHOUT deleting. The comment: "Nothing inserted
   means the parent was already gone or already decomposed; leave the parent
   alone rather than deleting blindly."
3. Otherwise `DELETE FROM ip2city_dbiplite_tbl WHERE network = $1::cidr AND
   source = 'dbip'`.
4. Commit.

So the parent db-ip row and the children never coexist outside the transaction,
and a failed insert cannot orphan the parent.

## Verified: children are independent for ip-api probing

`insertColumns` is:

    network, continent_code, continent_geoname_id, continent_names,
    country_geoname_id, country_iso_code, country_is_in_eu, country_names,
    city_names, latitude, longitude, subdivisions_names,
    start_ip, end_ip, city, state, source

`ran_at` is NOT in that list, so every child is written with a NULL `ran_at`
and is therefore unprobed. The file header records the consequence:
`check_geo_ip-api` selects ranges lacking a geolocated row in
`ip2city_dbiplite_traceroute_tbl`, so children are picked up automatically.

Note this is why `-inherit-location` matters and `ran_at` is excluded
regardless of it: a child may inherit the parent's city for reporting, but it
must not inherit the parent's PROBE STATUS, or it would never be measured.

## Verified: children are NOT independent for RDAP identification

`loadCandidates` in `rdap_registrant/cmd/main.go` restricts candidates with

    JOIN ip2city_dbiplite_tbl d ON d.network = c.network AND d.source = 'dbip'
    WHERE family(c.network) = 4 AND masklen(c.network) < 24

A /25 child is `source = 'routeviews'` at masklen 25, so it fails BOTH filters.
A decomposed child never receives its own RDAP query.

`loadParents` in `apply_splits` applies the same `d.source = 'dbip'` join, so a
child is never reconsidered as a parent either, and the run reports it under
"already /25 or narrower".

For the consumer that gates on it this is harmless: the registrant exists to
decide WHETHER to decompose, and a child is already decomposed. Whether /25
registrants are wanted for another purpose is an OPEN QUESTION for Boris, not a
defect I should assume. If wanted, it is a change to these two filters.

## The one real residual, and its status

VERIFIED mechanism: the fill skips any candidate that a cached allocation
wholly contains (`lookupCovered` requires `covered[i].start <= lo &&
covered[i].end >= hi`). ARIN returns the most specific network containing the
address queried, so a reassignment narrower than the cached allocation is never
fetched for a skipped candidate, and `ORDER BY ... LIMIT 1` cannot prefer a row
that is not there.

The precision question is therefore entirely on the FETCH side. The
consumption side is correct.

UNMEASURED: how often this occurs. No number has been established and none
should be quoted.

UNVERIFIED ASSUMPTION behind the reasoning: that db-ip ranges are mutually
disjoint, so no candidate contains another candidate and every retirement comes
from an ARIN allocation spanning several db-ip ranges. Not checked against
`ip2city_dbiplite_tbl`.

HYPOTHESIS, not a finding: the candidate total moving from 281,951 to 281,935
is decomposition removing 16 parents from the candidate set. Consistent with
the delete above; the 16 rows were not identified.

### How the residual could be settled

Sample already-retired candidates, query each directly, and count how often
ARIN returns an allocation narrower than the cached one that retired it. It
cannot be answered from held data, because the answer is precisely what was
not fetched. It needs its own queries, so it either waits for the fill to
finish or accepts a brief doubling of the ARIN request rate.

Error direction if the residual is real: `decomposition_exclusions` is tested
with `registrantExpr ILIKE x.operator_pattern`. A large ISP allocation is
generally not excluded while a specific sub-assignment to a datacentre would
be, so the bias is toward decomposing and probing space that should have been
excluded, rather than toward wrongly withholding decomposition.
