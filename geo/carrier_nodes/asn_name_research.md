# Is there an FCC dataset giving FRN to ASN? 2026-11-20

Boris: "You should use ASN as primary determinant, if it can be derived from
the FCC data." Then: "do that."

## ANSWER: NO. Nothing the FCC publishes carries an AS number.

What was checked, and what each gave:

| source | carries | ASN? |
| --- | --- | --- |
| BDC public availability file | frn, provider_id, brand_name, location_id, technology, two speeds, low_latency, business_residential_code, state_usps, block_geoid, h3_res8_id | NO |
| FCC "Explanation of Broadband Deployment Data" | describes Provider_Id as "filing number (assigned by FCC)" | NO |
| FCC Form 477 instructions and filing guides | filer identification, deployment, subscription | NO |
| CORES, the FRN registry | FRN, registered entity, TIN or EIN, financial standing | NO |
| FCC Form 499 Filer Database | filer id, legal name, trade names and DBA, FRN, addresses, officers, agent for service | NO |

The FCC's identifiers are the FRN, from CORES, and the provider_id, which is a
filing number. Neither is an internet-routing identifier and nothing in the
BDC or Form 477 lineage records one. The AS number is issued by a Regional
Internet Registry, not by the FCC, so there is no reason for the FCC to hold
it and the search found no instance of it doing so.

Sources, all fcc.gov:
- https://www.fcc.gov/general/explanation-broadband-deployment-data
- https://www.fcc.gov/licensing-databases/commission-registration-system-fcc
- https://apps.fcc.gov/cgb/form499/499a.cfm
- https://www.fcc.gov/file/3678/download (Form 477 filing guide)
Content from these pages was rephrased for licensing compliance.

## WHERE ASN TO ORGANISATION DOES COME FROM, and it is not the FCC

- Regional Internet Registry WHOIS and RDAP. Authoritative for the holder of
  an AS number. This project ALREADY queries RDAP: geo/rdap-lookup, and
  rdap_name is on carrier_crosswalk_tbl.
- CAIDA's Inferred AS to Organization Mapping, which infers ASN to
  organisation from RIR WHOIS and publishes it as a dataset.
  https://www.caida.org/catalog/datasets/as-organizations/
- PeeringDB, user-maintained, organisation to ASN with sibling ASNs often
  named in free text. https://www.peeringdb.com/
- ip-api's own "as" string, already held per probed range in
  ip2city_dbiplite_probe_tbl."as", of the form
  'AS7922 Comcast Cable Communications, LLC'. The number is a hard key and
  the remainder is the RIR's name for the holder.

So ASN can be the primary determinant on the ip-api side, where it exists as
a hard key, and the matcher is rebuilt around it. It cannot be the join to
the BDC, because the BDC has no ASN to join to.

## A BETTER BRIDGE THAN BRAND NAMES, and what is still unverified about it

The BDC carries the FRN. The Form 499 Filer Database is searchable BY FRN and
publishes each filer's LEGAL name and its trade names and DBAs, with a bulk
export described on the page as an Excel dump of all 499 filings.

That matters because the mismatch Boris asked about is brand against legal
name. ip-api reports 'Comcast Cable Communications, LLC', which is a legal
name; the BDC brand is 'Xfinity', which is marketing. A legal name to legal
name match needs no knowledge of which brand belongs to which company.

VERIFIED: the database exists, is public, is searchable by FRN, and the page
offers a bulk export. Taken from the fcc.gov page's own description.

NOT VERIFIED, and I am not asserting any of it:
- the columns of the bulk export, or whether the FRN appears in the export
  as opposed to only in the search form;
- whether every BDC filer appears in the 499 database. A Form 499 filer is a
  telecommunications carrier or interconnected VoIP provider; a
  broadband-only provider may have no 499 obligation, so coverage may be
  partial;
- whether it downloads from Boris's machine. apps.fcc.gov returned HTTP 403
  to this sandbox, the same refusal already recorded for www.fcc.gov and
  data.fcc.gov, so the fetch must be tried from his side.

Next step if Boris wants it: one probe from his machine for the bulk export,
then load FRN to legal name and re-run the matcher against legal names as
well as brands. That is a cheap experiment with a measurable answer, which is
whether Comcast reaches Xfinity without anybody naming it.
