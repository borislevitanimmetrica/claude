# Standing orders

Boris's instructions that apply to every session, not just the one they were
given in. Read this first. Added to whenever a new one is issued.

## 1. Never guess. Never guess SILENTLY.

The original order: when an answer, diagnosis or conclusion can only be
produced by guessing, do not present it as fact. Flag it as a guess or
hypothesis and state what evidence is missing. Prefer getting ground truth —
run a command, read the actual bytes, ask — over inferring. Distinguish
VERIFIED facts from INFERENCES.

**Extended 2026-11-06, and this is the part I kept breaking.** It is not
enough to avoid stating a guess as fact. **A guess must be labelled at the
moment it is made, in the same breath.** Not justified afterwards when
challenged. If information needed to proceed is unavailable, say so clearly and
immediately, say what evidence is missing, and say what would settle it. Do not
quietly fill a gap with a plausible value and carry on.

### Why this order exists, with the receipts

Four nonexistent database columns in one session, each one a silent assumption:

| what I wrote | what is true | where I took it from |
|---|---|---|
| `rdap_registrant` | `rdap_registrant_tbl` | a filename |
| `rdap_registrant_tbl.registrant_zip` | no address column exists on that table at all | wishful thinking |
| `ip2city_dbiplite_traceroute_tbl.sampled_ip` | dropped from the deployed table | the INSERT at `geo/main.go` line 1325 |
| `ovt_places_usa_ip_trace.ran_at` | `traced_at` | the demand table, assumed to apply to the supply table |

The fourth is the worst of them. It was in a file whose own earlier query had
just printed `ran_at | DEMAND ONLY` and `traced_at | SUPPLY ONLY`. The file
contained the answer and I did not read it, because I had decided the columns
were "proven" after proving them against a different table.

Each cost a round trip. None of them needed to happen: `information_schema`
answers the question in milliseconds.

### What the order covers

Everything, not just schema. Table names, column names, flag semantics, rate
limits, file formats, row counts, API behaviour, and causal explanations of
failures. If I have not observed it, I say I have not observed it.

### The practical rule that follows

- Before writing SQL against any column, confirm it from
  `information_schema.columns`. A source file states what the current build
  **would write**, not what the deployed table **holds**, and the two drift.
- Columns proven on one table are proven for **that table only**.
- In any new analysis file, section 1 dumps `information_schema.columns` for
  every table it touches, and every later section uses only columns proven for
  the specific table being queried.

## 2. No destructive action without a pre-mortem in the same turn

Before proposing any destructive or irreversible action — delete, truncate,
wipe, reset, flash, format — complete the full adversarial pre-mortem in the
SAME message as the proposal. Enumerate what state, evidence, logs or
capability the action destroys, and confirm nothing recoverable has been left
unpulled. Never propose, then realise consequences a turn later. If new
consequences surface mid-turn, retract explicitly rather than proceeding.

Applied well once this session: `migrate_into_landmarks_usa.sql` was one
message from being recommended, and its `DELETE FROM landmarks_usa WHERE source
IN (SELECT DISTINCT source FROM lm_places_usa)` would have destroyed 1,032,744
completed RDAP lookups and 10,044 on-premises determinations. Reading the file
before issuing the command is the only reason that is a commit and not an
incident. Prefer a mechanical guard over a comment: `reload_bad_id_sources.sql`
raises an exception rather than deleting if any row carries enrichment.

## 3. Frequent feedback from all code

A silent multi-minute phase is indistinguishable from a hang and has cost real
time. Every long step reports progress.

**psql cannot report progress inside a single statement.** `\echo` only fires
between statements, so the obligation is to keep every statement short enough
that section-level markers are frequent — not to promise progress and then
emit one twenty-minute query. `category_yield.sql` section 5 broke that rule by
putting a correlated `NOT EXISTS` inside an aggregate `FILTER`, which the
planner ran per group against a 15.2M-row table.

State a measured time before a slow step, not an estimated one, and label an
estimate as an estimate.

## 4. Paste-path hazards

These apply to anything Boris pastes into a shell. They do **not** apply to
files delivered by `git pull` and run with `psql -f`, which is why `\echo` is
used freely in committed SQL.

- A mid-line `#` is stripped to end of line. A full-line comment is fine. Never
  emit `$#`, `${#var}`, or a trailing inline comment.
- Backslash escapes are converted to real newlines. Emit no backslashes in
  pasted code.
- Only runnable commands go in fenced blocks. Expected program output must go
  in prose or a table, because a fenced block gets pasted and executed.
- No placeholder values. No `DATABASE_URL='postgres://…'`, no `1.2.3.4`, no
  `/path/to/file`. Use the real value, reference the existing environment
  variable, or ask.
- Any command block containing `sudo` starts with `sudo -v` on its own line.

## 5. Command order is part of the command

Issued 2026-11-09, after a run command was given without the `git pull` that had
to precede it. The tool rejected `-verify-sample` because the flag existed only
in a commit Boris had not pulled, and the failure was entirely mine.

**Never present commands in an order different from the order they must run
in.** No "run this, but first run that". No "#2, which I would run first". If
something must happen first, it goes first in the message. If I want to
recommend a different order, I reorder the blocks — I do not annotate them.

**Always state explicitly whether commands must run sequentially or may run
concurrently.** Every multi-command block and every set of blocks carries one of:

- SEQUENTIAL: each command requires the previous one to have completed.
- CONCURRENT: these may run at the same time, in any order.
- Or, when it matters, which specific pairs conflict and why.

This includes the dependency that is easiest to forget: anything that uses code
or SQL I have just written requires `git pull` to have completed first, and that
pull belongs in the same block, ahead of it, joined with `&&`.

A long-running job in another terminal is part of the ordering question too. If a
new command contends with it — same table, same remote rate limit, same lock —
say so when issuing it, not afterwards.

## 6. Batch commands that are expected to succeed

Issued 2026-11-12. Where several commands are to be run in sequence and NO
error is expected in any of them, put them in ONE block so there is a single
copy-paste rather than seven.

This does not weaken order 5. Still state SEQUENTIAL or CONCURRENT, and still
put a `git pull` ahead of anything that needs it. The distinction is:

- Expected to succeed, order known, nothing to read in between: ONE block.
- A step whose OUTPUT must be read before deciding the next, or where failure
  is plausible and would make later steps harmful: SEPARATE blocks, with what
  to look for stated.

A mutation with a pre-mortem still gets its own block, because the point of
the pre-mortem is a decision between steps.

## 7. Do not second-guess the original instance

Where a previous session made a decision and recorded its reasoning, report
disagreement rather than silently redesigning. `prefer()`'s physical-versus-
mailing contract and the district-level name-column defect were both left
alone and flagged for Boris on that basis.

## 8. Always absolute paths

Issued 2026-11-18. Boris: "Always issue absolute paths. What reason not to?"

There is no reason not to. The only thing a relative path saves is typing, and
it costs a failed command every time the working directory is not the one I
silently assumed. It failed exactly that way the same day:

    boris@Immetrica-Mint30:~$ python3 -u geo/carrier_nodes/coverage_holes.py fetch ...
    python3: can't open file '/home/boris/geo/carrier_nodes/coverage_holes.py'

I had put a `cd` in one block and then left it out of later blocks, as though a
shell carried a directory between separate pastes. It does not.

This applies to three places, not one:

- Every command I issue in chat.
- Every command a script PRINTS as a next step or a remedy. A script that
  reports a missing prerequisite and then names it by a relative path has
  handed over the same failure.
- Every path inside a script that is not derived from the script's own
  location. Where a script needs a sibling file, derive it from `__file__`
  rather than from the caller's working directory.

## 9. Think one step ahead: read new code for bugs before issuing it

Issued 2026-11-18. Boris: "Add to standing orders: always think one step
ahead, analyzing proposed code for possible bugs."

This extends order 1. Not guessing is about what I claim; this is about what I
hand over. Before any code or command goes out, work out what it will DO on
the next step and the step after, and name the ways it can fail. The question
is not "is this syntactically right" but "what state will this leave, and what
will the following command then find".

The failures this comes from were all one step of thought away:

- `-m 3600` on a 1.2 GB download: a total-elapsed-time limit, which aborted at
  90 per cent purely because an hour had passed. Then the failure path DELETED
  the partial, so the retry began at zero. Both were visible by asking what
  happens when the transfer is slow.
- A prerequisite message that listed every remedy in the chain instead of the
  one actually missing, telling Boris to reload counties he had just loaded.
- An advisory lock held in `pg_sleep(86400)`, which would have locked out
  every later loader for a day after any crash. Caught only because I tested
  it.
- Clearing the staging meta row without emptying the staging table, so one
  successful load blocked every load after it.
- `--min-nodes` defaulting to 3, which silently discarded whole rural sites.
- A self test that exercised Census alone when the shipped path was Census
  then Nominatim.

The habit that catches these: after writing something, re-read it as the
machine will run it, in the state the machine will actually be in — a slow
network, a part-finished download, a table that already exists, a second
process already running, a sparse county with two nodes. Where I cannot
predict the result, test it rather than issue it.
