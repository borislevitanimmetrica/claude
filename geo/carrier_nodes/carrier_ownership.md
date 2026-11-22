# Corporate ownership and why it breaks name matching

Facts supplied by Boris, with the consequence each one has for the
ITDK-BDC crosswalk. This file exists because ownership is the one thing
no string comparison can see, and because twice now I have treated an
ownership artefact as a bug in my own code.

## The facts

| parent | subsidiary | source | status |
|---|---|---|---|
| T-Mobile | Lumos (50%) | Boris, earlier in the same session | recorded, date not verified |
| Verizon | Frontier Communications | Boris 2026-11-22 | recorded, verified |

A note on the dates. My clock was wrong for part of this session, so any
date I wrote before Boris corrected it on 2026-11-22 17:29 EST may be a
day early. The two facts above are what matters and neither depends on
the date; where I cannot verify which day a ruling arrived I say so
rather than pick one.

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
a tier 1 match from a Frontier ASN to the Verizon brand.

## A second retraction: the hazard I described does not exist

What I wrote was:

> But there's a real risk here: a naive tier1 match on "Verizon Business"
> could wrongly pull in Verizon's own BDC brand (which covers ~97% of
> tracts nationwide), assigning Frontier's actual ranges to Verizon's
> much larger footprint. That same trap applies to Lumos under T-Mobile.

Boris refuted it on 2026-11-22 and the measurements agree with him.

**The 97% is not a wireline footprint.** Measured on his data earlier in
the same session: AT&T reaches 97.4% of tracts pooled across all
technologies and 97.3% on technology 71, licensed fixed wireless, alone,
against 44.3% on Copper and 36.4% on FTTP. And no brand exceeds 80% in
ANY single technology except 71, where three do. Since Boris has ruled
fixed and mobile wireless out of ZIP scope, the pooled figure measures
the half of the footprint this pipeline never selects on. There is no
"much larger footprint" to be assigned to. The same deduction disposes
of the T-Mobile half of my claim: T-Mobile's pooled 98.9% cannot be a
wireline number, because no brand reaches 80% on a wireline technology.

**The technologies are separated for a physical reason, so a pooled
share is not a quantity that exists.** Boris 2026-11-22: his nearest
Verizon central office, one mile away, carries xDSL but not FIOS; his
FIOS is routed from four miles away. One carrier, one subscriber, two
technologies, two different headends at two different distances. There
is no footprint of a brand, only one footprint per technology.

**Mergers between carriers extend the footprint rather than overlapping
it.** Boris 2026-11-22: eliminating a competitor standing on the same
streets is a pointless purchase. Verizon and Frontier are the strongest
possible case for this, because Frontier's territory IS ex-Verizon
territory: Verizon sold its wireline operations in 14 mostly rural
states to Frontier in 2010, and the California, Florida and Texas GTE
properties in 2016, keeping the northeast
([Converge Digest](https://convergedigest.com/verizon-completes-105-billion/),
[Frontier 8-K](https://www.sec.gov/Archives/edgar/data/732712/000119312516562197/R8.htm)).
The 2026 re-acquisition therefore moved Verizon into counties where
Verizon had no plant. Content was rephrased for compliance with
licensing restrictions.

**The flag I built on that reasoning had zero discriminating power.** On
his 2026-11-22 run the section listing candidates above 50% of the
country returned 40 rows: every one an AT&T or Verizon ASN matching its
own correct brand. AS5650, the single row that genuinely needed an eye,
sat among them indistinguishable. A flag that fires on 40 rows to catch
1, with nothing separating them, is worse than no flag, because it
teaches you to scroll past the section.

The same run showed the column failing from the opposite direction:
brand `Windstream` under provider 131413 came out at **0.0%** while
AS7029 has 63,297 ZIP-capable ranges behind it, because a carrier's
plant fragments across several brand spellings. So the pooled share is
unusable at both ends of the scale.

### A retraction

I previously cited AS5650 showing `as_operator = "Verizon Business"` as
evidence that the `mode()` pick was unweighted and arbitrary. **That was
wrong.** Verizon owns Frontier, so the name is correct. The unweighted
`mode()` was a real defect in the code, but AS5650 was not evidence of
it; the evidence is in `asn_match_fixture.sql`, which reproduces it on
constructed rows where the rare name wins under the old expression and
the common name wins under the new one.

### What the signal actually is

It was already in the output, in the column beside the one I was
watching. On his run, among the forty rows, exactly two read:

| ASN | registry operator | ip-api ISP | ranges |
|---|---|---|---|
| 5650 | Verizon Business | Frontier Communications | 16,801 |
| 46690 | Verizon Business | Frontier Communications | 1,548 |

The two names **disagree**, and the ISP name is itself a BDC brand. Every
other row in that list agreed on both names. So the instrument is not
footprint size, it is disagreement plus a second brand to point at, and
it yields a proposed answer rather than a warning: these two ASNs should
take Frontier plant.

`asn_isp_disagree_tbl` implements it. For each candidate where
`tier_isp_agrees = 0`, it asks which other BDC brand the ip-api ISP name
reaches at tier 1 or 2 and names it with its `provider_id`. The fixture
asserts that AS99003 produces exactly one such row naming `Frontier`,
and that the ASNs agreeing on both names produce none, because an
instrument that flags the agreeing ones is the flag I just removed.

`brand_tract_pct` survives, rebuilt to mean something: it is now
computed **per technology** over the wireline technologies 10, 40 and 50
only, and the widest single technology is reported with it. There is
also a section for candidates with **no wireline footprint at all**,
which is the case where a perfect name match still cannot be used:
Boris's run showed `Buckeye Wireless` and `Armstrong Telephone Company`
at 0.0%.

## What ownership does NOT justify

It does not justify my inferring an ownership relation myself and
collapsing two providers on the strength of it. Every row in the table
above came from Boris. The decision is recorded per ASN in
`asn_bdc_brand_map_tbl`, which is where an ownership fact becomes
operational: AS5650 gets `decision = 'brand'` pointing at Frontier's
brand and `provider_id`, not Verizon's, because the footprint is the
thing being selected.
