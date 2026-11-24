# Standing orders

Boris's rules. Every one of these was written after I broke it. They are
listed with the failure that produced them, because the failure is the reason
and a rule without its reason gets rationalised away.

He asked on 2026-11-24: "Seriously, how to force standing-orders
compliance?" The answer this file encodes: **the orders that stopped being
broken are the ones I made mechanical.** `check_sql.sh` caught my own
unbalanced apostrophes the same day I wrote it. The regression gate has
blocked every stopword regression since it was built. The orders that keep
being broken are the ones that live only in prose, and those are now checked
by `geo/sessions/check_block.sh`, which I must run on every command block
before issuing it.

## Before issuing ANY command block

Run it through the checker. No exceptions, including one-liners.

    sh /home/boris/geo/src/claude/geo/sessions/check_block.sh /tmp/block.txt

It fails on: a placeholder, a report command without logging, a mid-line
hash, a backslash, `sudo` without a preceding `sudo -v`, and a relative path.

## The orders themselves

1. **Never guess, and label a guess at the moment it is made.** Not after
   being challenged. If the information is unavailable, say so, say what is
   missing, and say what would settle it. Distinguish VERIFIED from INFERRED
   every time.

2. **Never take an identifier from prose**, including Boris's own prose or my
   own notes. Verify against `information_schema` and grep the repository.
   Cost: four nonexistent columns in one session.

3. **A precheck that only prints is not a precheck.** `\set ON_ERROR_STOP on`
   plus a `DO` block that `RAISE EXCEPTION`s. A `SELECT` the reader is
   trusted to notice is not a guard.

4. **Think one step ahead.** Before issuing code, work out what it leaves
   behind and what the next command will find. Run time is part of this: a
   command that scans half a billion rows must be labelled as long-running.
   Broken 2026-11-24 by handing over `step4_tract_site.sql`, which says
   519,469,683 rows in its own echo, with no warning.

5. **No placeholders in anything he will paste.** He pastes verbatim. Broken
   2026-11-24 with `--sheet 'SHEETNAME'`. If a value is unknown, ask for it
   or make the tool work it out; never leave a slot.

6. **Log every report.** A command whose output is a report must `tee` to
   `/home/boris/geo/logs/`. Broken 2026-11-24: four screens of tables with
   nothing retained.

7. **Absolute paths everywhere**, in chat, in scripts, and in any path a
   script prints as a next step. Each block is pasted independently, so a
   `cd` in an earlier block does not carry.

8. **Paste hazards.** No mid-line `#`, which is stripped to end of line. No
   backslashes, which are converted. Program OUTPUT never goes in a fenced
   block; only runnable commands do.

9. **`sudo -v` on its own line first** in any block containing `sudo`.

10. **Full adversarial pre-mortem in the SAME turn as a destructive
    proposal.** Enumerate what the action destroys before proposing it, not
    after. The too-late correction has cost him days.

11. **A fixture that cannot produce the failure is not a test.** State what
    shape of input exhibits the fault and confirm the fixture has it. Add a
    discrimination check that fails if the fixture stops reproducing it.

12. **One rule, one definition.** Two tests of the same thing drift. The
    carrier universe and the matcher disagreed and the cleanup deleted 769
    approved decisions over it. Where a cache is needed, populate it BY
    CALLING the rule and assert the two agree.

## Rules specific to this project

13. **Wireless is out of scope** for the ITDK-BDC subsystem: technologies
    70, 71 and 72 cannot carry a ZIP answer. They must never appear in a
    denominator or a distance. This bug has now shipped THREE times, in
    `provider_brand_footprint`, in `carrier_tract_tbl` and in
    `carrier_link_audit.sql`. Any new query over `bdc_availability_tbl` or
    `provider_tract_tech_tbl` must state its technology filter explicitly.

14. **A match is a complete name match or a pairing he has confirmed.**
    Nothing else. No token equality, no containment, no stopword-derived
    similarity. Stopwords find candidates for review and never decide.

15. **Per carrier AND per technology.** Verizon FIOS is not Verizon xDSL.
    A number pooled across technologies is not an answer.
