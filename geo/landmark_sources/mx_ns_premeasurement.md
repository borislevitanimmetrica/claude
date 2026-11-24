# MX and NS yield, pre-measured on the fire corpus

Measured 2026-11-03, DNS only. No Postgres, no RDAP, no `provider_names`.

`mx_ns_yield.py` exists to answer this question against `landmarks_usa` and is
ready to run. It needs the database, which I do not have. So I ran the same
question against a corpus I do have in full: the 8,412 distinct website hosts of
the USFA fire registry, which is a population of exactly the kind of small
municipal institution the landmark method depends on.

## The answer

**The MX and NS path will recover almost nothing.** The apex test gives an upper
bound of 7.9 per cent, and resolving those records collapses it to roughly one
or two per cent.

| measurement | hosts | share |
|---|---|---|
| distinct website hosts | 8,412 | |
| website resolved to an address | 7,404 | 88.0% |
| zone apex resolvable | 8,252 | |
| **publish no MX at all** | 1,620 | |
| **NS under the organisation's own apex** | 166 | **2.0%** |
| **MX under the organisation's own apex** | 656 | **7.9%** |

The apex is taken from `dns.resolver.zone_for_name`, the DNS delegation, not
from string surgery, so `.k12.<state>.us` and similar come out right.

## Why the upper bound collapses

"MX under its own apex" does not mean the mail server is on the premises.
`mail.example.org` can be an address inside a shared web host. I resolved all
1,119 self-apex records, 1,007 distinct names, every one of them, and read the
PTR:

**MX, 612 hosts with a self-apex record that resolves.** 301 of those 612 point
at **the same address as the website**, which means the record is the mail
service bundled with the web hosting plan, not a separate machine. The PTR
parents say the same thing:

| count | PTR parent |
|---|---|
| 57 | bluehost.com |
| 54 | eigbox.net |
| 49 | (no PTR) |
| 44 | unifiedlayer.com |
| 21 | secureserver.net |
| 14 | inmotionhosting.com |
| 13 | yourhostingaccount.com |
| 12 | hostmonster.com |

Every named entry there is a shared web host. Rule 2 rejects all of them, for
the same reason it rejects the website. Only the 49 with no PTR could hide
something on-premises.

**NS, 161 hosts.** Only 13 share the website's address, so these are at least
distinct machines, but they are not the fire station's:

| count | PTR parent |
|---|---|
| 65 | (no PTR) |
| 27 | mn.us |
| 20 | af.mil |
| 19 | dnsmadeeasy.com |
| 16 | amazonaws.com |
| 12 | facebook.com |
| 8 | usmc.mil |
| 6 | army.mil |
| 6 | spectrum.com |

`mn.us` is the State of Minnesota's network and `af.mil`, `usmc.mil`, `army.mil`
are military. Those are real on-premises networks, but they are the **state's**
or the **base's** premises, which is the `nwresd.k12.or.us` problem again: a
landmark built from them would place 27 Minnesota fire stations at one state
data centre. `node_fanout.sql` would correctly throw them away.

## What this does and does not settle

It settles the question **for this population**, and it is the population most
like the institutions the method relies on: small municipal bodies.

It does **not** measure your rejected `landmarks_usa` set directly. Overture
businesses, colleges and `.gov` municipalities may behave differently, and
`mx_ns_yield.py` is the right instrument for that. But the mechanism is the
same, and the mechanism is the finding: small organisations have outsourced
mail to Microsoft and Google and DNS to GoDaddy and Cloudflare, and where they
have not, the thing they kept is the shared web host.

Measured concentration on the mail side, 8,252 apexes:

| count | MX parent |
|---|---|
| 2,590 | outlook.com |
| 1,161 | google.com |
| 425 | barracudanetworks.com |
| 299 | googlemail.com |
| 259 | ppe-hosted.com |
| 160 | mimecast.com |

4,050 of 8,252 on Microsoft 365 or Google Workspace before counting the mail
filtering services in front of them.

And on the DNS side:

| count | NS parent |
|---|---|
| 1,778 | domaincontrol.com (GoDaddy) |
| 1,288 | cloudflare.com |
| 489 | worldnic.com |
| 304 | wixdns.net |
| 283 | azure-dns.com and three sibling zones |
| 245 | civicplus.com |

## Recommendation

**Do not build the full MX/NS path.** Run `mx_ns_yield.py` once against
`landmarks_usa` to confirm the same shape on your own corpus, because it is a
measurement that writes nothing and costs one sample. If it reports a
newly-qualifying rate in the same one-to-eight per cent band, close the
question.

It needs dnspython:

```
pip3 install --user dnspython
```

Then, fully qualified:

```
python3 /home/boris/geo/src/claude/geo/landmark_sources/mx_ns_yield.py --sample 2000 --out /home/boris/geo/logs/mx_ns_winners.csv 2>&1 | tee /home/boris/geo/logs/mx_ns_yield.log
```

## The one number worth having from the fire corpus

44.0 per cent of the 7,404 resolved website addresses, **3,260 of them, have no
PTR at all.** I cannot tell you what those are. 46.2 per cent sit under the 40
commonest PTR parents and those are hosting providers, so they are rule-2
rejections. The no-PTR block is the only place the fire registry's on-premises
yield can come from, and nothing short of RDAP will classify it.

That is measurable the moment the source is loaded, and it is the number that
decides whether website discovery for the address-only registries is worth
building at all. See `website_discovery_sequencing.md`.
