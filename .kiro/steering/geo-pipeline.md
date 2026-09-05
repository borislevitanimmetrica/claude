# Geolocation pipeline rules

Durable decisions for the `geo/` tooling. Verified facts are marked; everything
else is a decision, not an inference.

## Probe design

- **One probe per /24. Never more.** Measured 2026-09-01: 21 probes inside three
  separate /24s (`66.166.1.0/24`, `73.45.96.0/24`, `73.45.32.0/24`) returned
  byte-identical city/ZIP within each /24. Additional probes in the same /24
  yield zero new information.
- For ranges wider than /24, probe the /24 subnets **aligned to the start of the
  range** — i.e. all /24s in it, `network + i*256`. CIDR alignment makes this
  unambiguous.
- Probe count for a range = `2 ^ (24 - masklen)`, and exactly 1 for /24 or
  narrower.
- Rate limit: 45 probes/min on the free tier = 64,800/day. This is the scarce
  resource; optimise for probe count, not CPU.

## db-ip resolution is FINER than ip-api

- Measured 2026-09-01 on live data: db-ip holds **603,354** IPv4 ranges narrower
  than /24, **all labelled with a city** (zero unlabelled). Of the 102,537 /24
  blocks containing such rows, **84,986 (83%) contain sub-/24 rows that disagree
  on city.**
- Therefore: **never collapse sub-/24 db-ip rows into a /24, and never overwrite
  a sub-/24 db-ip row with a /24-level ip-api probe result.** Doing so destroys
  real, fully-labelled geographic detail.
- The two facts coexist: ip-api cannot resolve below /24, *and* db-ip can. Do
  not generalise a measurement of one source onto the other.

## DoD / government exclusions

- **Match DoD on prefix or origin ASN ONLY. Never on ZIP or city.** Columbus OH
  43218 and Sierra Vista AZ 85613 are the whois *registrant* addresses for DoD
  space, but they are also real metros with legitimate commercial ranges.
  Excluding by ZIP would discard valid data. Hard rule.
- Prefer `org`/`isp` text signatures over any location field when
  auto-detecting.
- Rules live in the `geo_exclusions` table (`prefix` XOR `origin_asn`).
- The 12 IANA-designated DoD /8s: 6, 11, 21, 22, 26, 28, 29, 30, 33, 55, 214,
  215. Source: IANA IPv4 Address Space Registry.
  `7.0.0.0/8` is IANA-designated to ARIN but originated by AS749 (DoD) in
  RouteViews — treat as a separate, explicit decision.
- Probing DoD space is worthless at **any** subscription tier: ip-api returns the
  registrant address, not subscriber geography. Paid tiers remove rate limits and
  add batching; they do not add data that does not exist.
- On-base housing is very likely served by commercial ISPs, not DoD ranges: US
  military family housing is ~99% privatised and residents pay their own
  utilities. This is an inference from those verified facts, not a verified
  ISP-level claim.

## Hot-path SQL performance

- Read `geo_exclusions` **once at startup** and inline the rules as a literal
  predicate. Do not use a correlated `EXISTS` or a join against the exclusion
  table inside the containment scan.
- Excluding by origin ASN is negligible as a compute optimisation: AS749+AS721
  are only 3,364 of 1,121,547 BGP rows (0.3%). Prefix exclusions matter because
  they cut *probe budget*, not CPU.

## Code delivery

- The user's paste path corrupts backslash escape sequences: `\n` inside a Go
  string literal arrives as a real newline, producing `newline in string` build
  errors. Root cause confirmed 2026-09-01.
- Therefore: **emit source containing no backslashes at all.** Use
  `fmt.Println` / `fmt.Sprintf` instead of `\n` in format strings; avoid psql
  meta-commands (`\echo`) in .sql files.
- Deliver via quoted-delimiter heredoc (`<<'EOF'`). Do **not** use base64 or
  gzip: a single corrupted character destroys the whole payload instead of
  producing a locally fixable error.
- Verify in the sandbox before sending: `grep -c` for backslashes must be 0, and
  the code must build.
- All SQL as double-quoted single-line Go strings; no backtick raw strings.
