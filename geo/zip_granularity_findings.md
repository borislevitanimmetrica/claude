# At what prefix length does ip-api's ZIP stop varying?

Measured 2026-10-12. 96 /24s drawn from 24 parent ranges in the live probe table,
spanning Comcast, AT&T, Charter, Verizon, CenturyLink, Suddenlink, Consolidated
and PCCW. Each /24 probed at eight addresses on /27 midpoints, which detects any
ZIP mixing coarser than /27. 768 ip-api calls, plus reverse DNS at no cost.

## Result

| classification | /24s | share |
|---|---|---|
| uniform at /24 | 89 | 92.7% |
| needs /25, uniform within each half | 3 | 3.1% |
| mixed within a /25 | 4 | 4.2% |

All four "mixed within a /25" cases are in one parent, `45.19.184.0/21`, and all
four are an artifact rather than geography. See below. Excluding that parent:

| classification | /24s | share |
|---|---|---|
| uniform at /24 | 89 | 96.7% |
| resolved at /25 | 3 | 3.3% |
| needs finer than /25 | 0 | 0% |

**So /25 resolves every real case observed.** /24 leaves 3.3% of ranges carrying
two ZIPs.

## The three real /25 splits

| range | operator | first /25 | second /25 | city |
|---|---|---|---|---|
| `107.196.31.0/24` | AT&T | 77054 | 77081 | Houston TX, both |
| `67.184.76.0/24` | Comcast | 60005 | 60004 | Arlington Heights IL, both |
| `67.184.77.0/24` | Comcast | 60005 | 60004 | Arlington Heights IL, both |

Each splits exactly at `.128`, four /27 samples agreeing on each side. In every
case the two ZIPs are ADJACENT and the city is IDENTICAL. That matters twice over:
it is consistent with a real serving-area boundary at /25, and it means the DMA
tier is untouched, because DMA resolves through city.

A fourth, found earlier by full enumeration: `76.90.65.0/24` Charter, 92544 for
`.0-.127` and 92543 for `.128-.255`, 128 addresses each.

## The Baton Rouge anomaly is ip-api error, proven by the operator's own DNS

`45.19.184.0/21` returns `39205` Jackson, Mississippi scattered through ranges
whose other addresses return Baton Rouge, Louisiana. 141 miles, two states, two
DMAs, alternating in blocks as small as eight addresses. Full enumeration of
`45.19.184.0/24` found it uniform only at /29, with ten separate runs.

Reverse DNS settles it. Every address in all four /24s, in both ZIP groups,
publishes the same signature:

    45-19-184-16.lightspeed.btrgla.sbcglobal.net
    45-19-184-20.lightspeed.btrgla.sbcglobal.net

`btrgla` is AT&T's own token for Baton Rouge LA. The operator says Baton Rouge for
every address ip-api places in Jackson. One distinct PTR signature across all four
/24s against two ip-api cities.

The hypothesis that these are unassigned addresses resolving to a headend is NOT
supported: all 128 sampled addresses published a PTR, so all are provisioned.
`39205` is also a PO-Box ZIP, which is what ip-api tends to return when it is
guessing.

Chasing this to /29 would mean 32 rows per /24 to encode vendor error as terrain.

## Reverse DNS is a free, unmetered, operator-authoritative signal we do not use

Observed encodings, verified on these ranges only:

| operator | PTR pattern | granularity |
|---|---|---|
| AT&T | `lightspeed.btrgla.sbcglobal.net`, `lightspeed.hstntx.sbcglobal.net` | CITY |
| Comcast | `hsd1.il.comcast.net`, `hsd1.or.comcast.net` | state |

AT&T encodes the serving city. It has no rate limit, costs nothing, and in the one
head-to-head case it beat ip-api decisively. It is not a complete answer, since
Comcast publishes only state and some operators publish nothing, but it is a
cross-check available for every address at zero marginal cost. `rdap-lookup.sh` and
`traceroute_hostname_rules.sql` already exist in this repository for last-hop
hostnames; this is the same idea applied to the target address.

## What this costs, and why the granularity decision is really a budget decision

/25 doubles the decomposed row count, from roughly 3.37 million to 6.74 million,
and doubles probe time with it.

At the measured free-tier ceiling of 45 calls a minute, which is 64,800 a day:

| granularity | rows | probe cycle |
|---|---|---|
| /24 | 3.37M | 52 days |
| /25 | 6.74M | 104 days |

Against that, ZIP values were measured drifting within TWO DAYS: re-probing the
same 16 addresses of `76.90.64.0/20` two days apart, 3 of 16 changed ZIP, all
collapsing toward 92543, on Charter wireline.

A 104-day cycle pursuing a value that moves in two days is not a measurement. The
granularity question cannot be settled on precision grounds alone while the free
tier is the constraint: /25 is the better granularity and is unaffordable without
the paid batch endpoint.

## Recommendation

1. Keep /24 as the decomposition floor for now. It is correct for 96.7% of real
   ranges, and the error in the remaining 3.3% is a neighbouring ZIP in the same
   city, which is the inaccuracy already accepted as inherent to ZIP targeting.
2. Treat /25 as the target granularity to adopt WITH the paid batch endpoint, not
   before. The evidence supports it; the budget does not.
3. Do not pursue anything finer than /25. The only evidence for it is a vendor
   artifact contradicted by the operator's own DNS.
4. Let `range2zip_tbl` carry the multi-ZIP ranges and `zip_landmark_count > 1`
   mark them, so the ZIP tier declines them rather than guessing.
5. Evaluate reverse DNS as a third source. It is free and unmetered, and it
   already caught an ip-api error spanning two states.

## Caveats

96 /24s from 24 parents is a small, non-random sample: the parents came from one
random draw of the probe table and the /24s were taken at fixed offsets within
each. The mixed-rate figures should be read as order-of-magnitude. The PTR
encodings were verified for AT&T and Comcast only.
