# Website discovery: the cheap test failed, and what that means

You approved building website discovery for the address-only registries. Before
building it I ran the two experiments that bound its value, because both are
measurable in under an hour and the alternative is a day of work aimed at a
number nobody has.

Both came back negative. I am reporting that rather than building on top of it.

## Experiment 1: can a domain be generated instead of searched?

The fire registry hands us **ground truth**: 8,685 institutions whose real
website we already know. So the question "could a discovery mechanism have found
this?" can be scored exactly, which is impossible on PSS or IMLS where there is
no answer key.

Method: from the department name, city and state, generate plausible registrable
domains (joined core words, `fd`, `vfd`, `firedept`, `firerescue`, initials,
across `.org .com .net .us`), check each for an A record, and ask whether the
true domain is among the live ones. 300 institutions, 13,036 distinct candidate
domains, 43 candidates generated per institution.

| result | count | share |
|---|---|---|
| institutions tested | 300 | |
| **true domain among the live candidates** | 106 | **35.3%** |
| **true domain was the only live candidate** | 3 | **1.0%** |
| institutions with 6 or more live false candidates | 151 | 50.3% |

**It does not work.** Recall is a third, and precision is almost nil: parked and
squatted domains resolve, so an A record is close to useless as a filter. The
median institution came back with five or six live candidates and no way to
choose between them.

The misses explain why, and the explanation matters more than the number:

| the real website | the institution |
|---|---|
| `www.storeycounty.org` | Storey County Fire Department |
| `www.gilbertaz.gov` | Gilbert Fire and Rescue Department |
| `www.cityofknoxville.org` | City of Knoxville Fire Department |
| `townofstratford.com` | Stratford Fire Department |
| `ci.orange.nj.us` | City of Orange Township Fire Department |
| `www.savmn.com` | St. Anthony Fire Department |

The institution very often has **no domain of its own**. It is a page on the
municipality's site. No name-based generator can reach that, and the
municipality's own domain is already loaded by `lm_fetch.py dotgov`, so finding
it again adds nothing.

Conclusion: discovery needs a real search index. There is no free substitute.

## Experiment 2: would a discovered website even be on-premises?

This is the question that decides whether discovery is worth paying for, and it
is separable from discovery itself.

`mx_ns_yield.py` records the governing measurement: over 12,775,630 rows, rule 2
rejects **10,713,526, which is 83.8 per cent**, because the website's address
belongs to a CDN, cloud or web host. And adding 1,460,317 rows across five
landmark sources produced **6 new ZIP codes**.

So the binding constraint is not whether an institution has a website. It is
whether that website is served from the institution's own address. Discovery
addresses the first and is indifferent to the second.

I measured the second on the fire corpus by DNS, 8,412 hosts, full detail in
`mx_ns_premeasurement.md`:

- 7,404 website addresses resolved
- **3,260 of them, 44.0 per cent, have no PTR at all.** Unknown. Only RDAP can
  classify these, and that is where any on-premises yield has to come from
- 46.2 per cent sit under the 40 commonest PTR parents, and those are
  AWS Global Accelerator, amazonaws, googleusercontent, firehousesolutions,
  secureserver, Akamai, CivicPlus, Weebly, Bluehost, Wix. Rule-2 rejections,
  every one

I cannot resolve the 44 per cent from here. **You can, for free, as a by-product
of a load you are already doing.**

## What I propose, and why in this order

Load the fire registry, run the chain on that source alone, and read the
on-premises rate. 8,685 landmarks whose websites are already known, in a
population of small municipal institutions, 7,418 ZIPs. That single number is
the per-source on-premises yield for exactly the class of organisation that
discovery would target.

```
cd /home/boris/geo/src/claude/geo/landmark_sources
python3 lm_fetch.py usfa-fire
python3 lm_fetch.py status
```

Then the shared chain, restricted to the one table, and the counts after it:

```
cd /home/boris/geo/src/claude/geo/overture_fetch
python3 ovt_resolve_hosts.py resolve --table lm_places_usa
python3 ovt_resolve_hosts.py rdap --table lm_places_usa
python3 ovt_resolve_hosts.py registrants --table lm_places_usa
python3 ovt_resolve_hosts.py overture-zip --table lm_places_usa
python3 ovt_resolve_hosts.py onpremises --table lm_places_usa
```

The decisive read is the `onpremises_reason` breakdown for `source = 'usfa_fire'`.
`landmarks_per_source.sql` in `geo/landmarks` already reports per-source counts.

**If that rate is poor**, in the same band as the 0.66 per cent and 6-new-ZIP
results, then discovery for PSS and IMLS is dead before it starts: we would be
paying a search API to find 56,000 websites that rule 2 will then reject. I will
say so plainly and we drop it.

**If it is good**, discovery becomes worth costing, and I will come back with
search-API options and a measured price per institution rather than an estimate.

The cost of finding out is one chain run on a source you are loading anyway. The
cost of skipping the question is a day of my work and a search-API bill aimed at
an unmeasured yield, which is the mistake the 6-new-ZIP result already recorded
once in this project.

## One thing I am NOT doing

I am not treating this as a reason to stop looking for landmarks. The fire
registry is real: 8,685 rows, 7,418 ZIPs, 2,277 of them unreached by any school,
99.2 per cent unique hosts. Load it. The question here is narrower, and it is
only whether to spend on *discovering* websites for registries that lack them.
