# Corporate ownership and why it breaks name matching

Facts supplied by Boris, with the consequence each one has for the
ITDK-BDC crosswalk. This file exists because ownership is the one thing
no string comparison can see, and because twice now I have treated an
ownership artefact as a bug in my own code.

## The facts

| parent | subsidiary | source | status |
|---|---|---|---|
| T-Mobile | Lumos (50%) | Boris 2026-11-21 | recorded |
| Verizon | Frontier Communications | Boris 2026-11-21 | recorded, verified |

Verizon closed its $20 billion acquisition of Frontier on 20 January
2026, making Frontier a wholly owned subsidiary
([Verizon](https://verizon.com/about/news/verizon-delivers-2025-financial-guidance-highest-quarterly-net-adds),
[Frontier wholesale notice](https://wholesale.frontier.com/dcaas-staticassets/wholesale/SourceFiles/2026Notifications/CCBFTR02379_Verizon_Frontier_Acquisition_Closed_01202026.pdf)).
Content was rephrased for compliance with licensing restrictions.

## What this does to the matcher

Ownership moves the **name** to the parent while the **footprint** stays
with the subsidiary. The two sides of the crosswalk therefore disagree
in a way that looks like a clean match:

- ip-api reports AS5650 with the AS operator name `Verizon Business`,
  because the registry record now carries the parent.
- BDC still holds Frontier's wire centres under Frontier's own
  `provider_id` and brand, because the filing is per operating company.
- The address space behind AS5650 serves **Frontier's** footprint.

`carrier_name_tier('Verizon Business', 'Verizon')` is 1: the token sets
are equal once `business` is dropped as a modifier. So the matcher offers
a tier 1 match from a Frontier ASN to a brand that reaches 97% of
census tracts. Accepting it would hand Frontier's ranges half the
country and the error would be invisible, because nothing about the
match looks weak.

### A retraction

I previously cited AS5650 showing `as_operator = "Verizon Business"` as
evidence that the `mode()` pick was unweighted and arbitrary. **That was
wrong.** Verizon owns Frontier, so the name is correct. The unweighted
`mode()` was a real defect in the code, but AS5650 was not evidence of
it; the evidence is in `asn_match_fixture.sql`, which reproduces it on
constructed rows where the rare name wins under the old expression and
the common name wins under the new one.

### What was done about it

Dropping the match is wrong: AT&T's own ASN legitimately matches a
nationwide AT&T brand, and only Boris can tell a parent sitting on a
subsidiary from a carrier sitting on itself. So the match is kept and
made **visible** instead:

- `asn_brand_candidate_tbl` carries `brand_tracts` and
  `brand_tract_pct`, the share of all census tracts the candidate brand
  reaches.
- A dedicated section lists every candidate whose brand exceeds 50% of
  tracts, which is a short list that needs an eye on it.
- `tier_isp_agrees` is the corroborating signal, and in this case it
  discriminates: for the Frontier ASN the registry says Verizon while
  ip-api's ISP name still says Frontier, so the ISP tier is 0 against
  the Verizon brand. A genuine national carrier agrees on both names.

The fixture asserts all three of these, including that the Verizon
candidate is still offered rather than filtered away.

## What ownership does NOT justify

It does not justify my inferring an ownership relation myself and
collapsing two providers on the strength of it. Every row in the table
above came from Boris. The decision is recorded per ASN in
`asn_bdc_brand_map_tbl`, which is where an ownership fact becomes
operational: AS5650 gets `decision = 'brand'` pointing at Frontier's
brand and `provider_id`, not Verizon's, because the footprint is the
thing being selected.
