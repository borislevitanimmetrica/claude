# Measurement scripts

Throwaway instruments, kept because the numbers they produced are quoted in
decisions and someone should be able to re-derive them rather than trust a
table in a markdown file.

None of these touch Postgres. They were run from a sandbox with no database,
which is why they exist at all: the question had to be answerable without one.

All three read `usfa_fire_national.csv`, the USFA national registry CSV. Fetch
it first:

```
curl -L -o usfa_fire_national.csv https://apps.usfa.fema.gov/registry/api/download/national
```

They need dnspython:

```
pip3 install --user dnspython
```

The paths at the top of each file point at the sandbox and must be edited, or
the CSV placed alongside the script.

| script | question | answer it gave |
|---|---|---|
| `fire_dns_probe.py` | who hosts each department's website, DNS and mail? | 44.0% of website addresses have no PTR; NS under own apex 2.0%, MX 7.9% |
| `fire_dns_pass2.py` | do those self-apex records actually point on-premises? | no: 301 of 612 MX share the website's address, the rest are shared web hosts |
| `discovery_trial.py` | can a website be generated from name plus place instead of searched? | no: 35.3% recall, sole live candidate in 1.0% of cases |

The written findings are in `../mx_ns_premeasurement.md` and
`../website_discovery_sequencing.md`.

`discovery_trial.py` takes a sample size, default 300:

```
python3 discovery_trial.py 300
```

It is scored against ground truth: every institution in the sample already has
a known website, so recall is exact rather than estimated. That is the whole
point of testing discovery on this corpus instead of on NCES PSS, where there
is no answer key.
