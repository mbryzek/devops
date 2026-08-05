# Weekly meta-review: gaps no single run can see

Review the last 7 days of producer runs and terminal issues, find the things that
are quietly broken across runs, and **file them**. Then stop.

**This producer files. It does not fix.** Every other producer in the registry
follows that rule and so does this one: nothing here opens a PR, changes a
playbook, or edits producers.yml. The output of a run is zero or more filed
issues plus a report. If you find yourself editing code, you have misread this
playbook.

**A quiet week is the normal outcome, and manufacturing a finding is worse than
silence.** An agent told to "look for gaps" will always find gaps — that is why
every detector below carries a stated bar, and why a candidate that does not
clear its bar is not filed, not filed-with-a-caveat, and not mentioned as a
"possible concern". It is dropped. Closing out having filed nothing is a
successful run.

## Why this exists

A session sees one night. It cannot see that it worked around the same broken
instruction on each of the last thirty nights — from inside the run, the
workaround is just how the job is done. A producer whose check crashes files
nothing and looks exactly like a producer that had nothing to say. An issue that
went `fixed` on a PR that never merged looks closed from every angle except the
one that checks GitHub. None of these announce themselves; all of them are
obvious the moment you line up a week of runs side by side. That lining-up is the
entire job.

## The window

The last 7 days, ending now. Every bar below is measured inside it. Where a
detector needs history older than the window (a producer's full run list, an
issue's occurrence count) take that history in full — the window bounds what
counts as *news*, not what you are allowed to read.

## The data, and the one place it lies to you

    dev agent producers                    # registry: every producer, cadence, last run, next due
    dev agent runs --limit 200             # global run history, newest first
    dev agent runs <key> --limit 50        # one producer's history — ACCURATE, see the trap below
    dev agent runs --issue <n>             # every lease attempt on one issue
    dev issues list                        # every issue, every status
    dev issues list --status <s> …         # repeatable; combine statuses
    dev issues show <n>                    # body, occurrence count, recorded fix URL, full timeline

**The trap.** `dev agent producers` reports `last run: never` / `next due: now`
for producers that have plainly run. It builds its per-producer "last run" by
fetching the most recent runs *globally* (`Agent::Api.producer_runs`, default
`limit: 100`) and grouping by key, so anything whose last run fell out of that
window — which at current volume is under a day — reads as never having run. Four
of the twelve weekly-review producers read that way as of 2026-08-05. Diagnosis
and the reason it is not being fixed in the agent (ISS-526 deletes the code path)
are recorded on ISS-522.

So: **never conclude "this producer has not fired" from `dev agent producers`.**
Confirm every such candidate with `dev agent runs <key>`, which filters
server-side before it limits and is therefore accurate. Skipping this step is not
a small error — it is four false issues on the first run.

## The detectors

Six, each with a bar. Work them in order. For each candidate, write down which
bar it clears and the evidence that proves it, in the form you would put in the
issue. If you cannot write that sentence, there is no finding.

### D1 — a producer whose check is broken

The check exits >1, which the contract records as `check_failed` and never as
`filed` — deliberately, so a crashing check does not become a nightly stream of
bogus issues. The cost of that correctness is silence, and this is what breaks
the silence.

**Bar:** the producer's most recent run is `check_failed`, **and** either its
previous run was also `check_failed`, or it has never had a non-`check_failed`
run. One failure between two successes is a transient and is not filed.

The two-sided bar matters. A plain count ("2+ `check_failed` in the window")
fails both ways: a weekly producer can have at most one run in seven days, so it
can never clear the count; and a producer whose check has since been *removed*
still carries its old failures, which is how you file an issue about a check that
no longer exists (`api-lint` is the live example — it failed on 2026-08-04 and was
converted to `file_when: always` afterwards).

**Confirm before filing.** Re-run the check yourself and paste the real output and
exit code. If the check is a multi-repo sweep that takes an hour
(`dev codegen sync --check` clones and regenerates every repo), do **not** run it:
say plainly in the issue that you did not, and cite the run record as the
evidence. Never imply you observed something you did not.

→ files `open`, category `bug`.

### D2 — a condition that keeps recurring and never gets fixed

The fingerprint dedup means a standing condition increments an occurrence count
instead of filing again. That is right, and it also means a condition can be
re-detected indefinitely with nobody ever working it.

**Bar:** an issue with `Occurrences: 3` or more whose timeline records no fix URL,
where the occurrences span at least two distinct days. Same-day repeats are a
double-fire, not a recurrence.

→ files `open`, category `bug`.

### D3 — an issue that went terminal without the thing it described being confirmed

**Bar**, either of:

- a `fixed` issue whose recorded PR is still open — not merged, not closed — 7 or
  more days after it went `fixed`. Get the URL from `dev issues show <n>`
  ("Previous fixes:"), then `gh pr view <url> --json state,mergedAt,isDraft`.
- a `deployed` issue whose app has not released past its recorded baseline
  version. `deployed` asserts the fix is live; if no release carries it, the
  assertion is false and the 7-day auto-verify is about to close it anyway.

A `fixed` issue whose PR was *closed unmerged* clears this bar on day one — the
fix is not coming and the issue says it shipped.

→ files `open`, category `bug`.

### D4 — a playbook instruction nothing can execute

**Bar:** a body under `agent/bodies/` instructs a write to an absolute path whose
parent directory does not exist on this runner. Mechanical, no judgment:

    grep -n '/Users/\|/opt/\|/var/' agent/bodies/*.md
    # for each absolute path named as a write target:
    ls -d "$(dirname <path>)"

Also file when a playbook names a command that is not on this runner's PATH
(`command -v <binary>`) — the same failure with a different noun.

This is the detector that would have caught ISS-503 on day one: four playbooks
end by writing `/Users/mbryzek/code/openclaw/openclaw-workspace/data/…`, and this
runner is `/Users/athena`. Note the shape — work ported from Mike's Mac onto a
runner that was never given the Mac's filesystem or tooling. When you find one,
check whether anything else ported in the same batch has the same gap.

Do **not** extend this to "instructions that seem fragile". The bar is a path or
a binary that provably does not exist here, tested with a command whose output
you paste.

→ files `open`, category `bug`.

### D5 — a producer that is dark

**Bar:** `dev agent runs <key>` — per key, never the global list, see the trap
above — shows no run within two full cadence periods (14 days for a weekly
producer, 48 hours for a daily one). A producer that has never run at all and
whose first period has not yet elapsed is not dark; it is new.

→ files `open`, category `bug`.

### D6 — a playbook that contradicts its own guardrail

The one detector whose output is a **decision**, not a defect. See the next
section for why that distinction is the most important thing in this playbook.

**Bar:** two quotable lines in the *same* file under `agent/bodies/`, where one
states a prohibition ("never", "must not", "strictly read-only") and the other
instructs the prohibited action. Quote both with `file:line`. If you cannot quote
two lines, there is no finding — "this playbook feels risky" is not a finding, and
a contradiction you have to paraphrase into existence is not one either.

The live example, and the reason this detector exists:
`agent/bodies/slow-query-review.md:50` says the shared clone is "strictly
READ-ONLY: `EXPLAIN` and `SELECT`, no writes", and line 68 of the same file says
"Create the candidate index". Both are defensible instructions; together they are
a question nobody has answered.

→ files `needs_input`. Never `open`.

## The classification test: defect → `open`, decision → `needs_input`

This is the part most likely to be got wrong, and the part with the worst
consequences when it is.

Ask one question of every finding: **does this have a right answer the fleet can
implement?**

- **Yes → `open`.** A path that does not exist, a binary that is not installed, a
  PR that never merged, a check that crashes. There is one correct outcome, any
  session can reach it, and the queue should take it.
- **No → `needs_input`.** Two or more defensible answers, and choosing between
  them is a judgment about how the system should work. Filing this `open` does not
  get it decided — it gets an autonomous session to pick Mike's answer for him,
  silently, in a PR that looks like a bug fix.

ISS-504 is the worked example. "The playbook says the shared clone is read-only
and the run wrote to it" reads like a bug report. It is not. It is a question with
two defensible answers — permit measured writes with a mandatory revert, or route
every write to the session's own database — and Mike chose the second. A
meta-reviewer that had filed it `open` would have had that decided by whichever
session claimed it first.

When it is genuinely unclear which side a finding falls on, it is a decision.
`needs_input` costs Mike one reading; `open` costs him an unasked-for answer.

### Writing a `needs_input` issue

State the observation with its evidence, then **both options, in full, with the
tradeoff**, then stop. Do not recommend one so strongly that the decision is
made. Do not implement either. Do not open a "just in case" PR.

`dev issues create` cannot file directly into `needs_input`, so it is two steps —
and there is a real race in the gap, because a claim sweep runs every 30 seconds
and only ever takes `open` issues:

    dev issues create --category improvement --status open --no-spawn \
      --title "Decision: <the question>" --body "$(cat <<'EOF'
    **DO NOT IMPLEMENT. This is a decision for Mike, not a bug report.**
    If you are an autonomous session that claimed this: set it back to
    `needs_input` and stop. Neither option below may be implemented until Mike
    has chosen one.

    <observation and evidence>

    ## Option 1 — <name>
    ...
    ## Option 2 — <name>
    ...
    ## Tradeoff
    ...
    EOF
    )"
    dev issues status <n> --status needs_input --comment "<the question, in one sentence>"

The banner is the mitigation for the race: a session that claims it in the gap
reads the first line and puts it back. Write the banner every time.

`needs_input` does reach Mike — `NotifyOpenIssuesProcessor` mails it at 7am ET
daily and never re-claims it — so this is a status that surfaces, not a drawer.
(It currently arrives under the wrong heading for internally-filed issues;
ISS-532 tracks that. It arrives.)

## Filing mechanics

- `--status open` for defects, never `claimed`. This producer is not going to
  work them, and a claimed issue nobody is working is invisible to
  `dev issues claim` — worse than mislabelled, it is unpickupable.
- **Dedup immediately before each `create`, not once at the start of the run.**
  `dev issues list --status open --status claimed` and scan for the same
  condition. The queue moves while you work, and this producer files exactly the
  kind of finding another session may have filed an hour ago. If you find a true
  duplicate: `dev issues duplicate <dup> --of <canonical>`.
- Check the epic ISS-519 and its children before filing anything about the
  producer subsystem. Producer scheduling, the registry and the playbook bodies
  are all being moved into the platform, and a defect in a code path ISS-526
  deletes is usually a **comment on the relevant child**, not a new issue. Say so
  explicitly in your report when you make that call.
- Cross-reference this issue's number in every issue you file ("Found by the
  weekly meta-review, ISS-<n>"), so a finding is traceable to the run that found
  it.
- One issue per finding. Never a single "meta-review findings" issue with six
  things in it — that is one lease, one outcome, and five findings nobody works.

## Do not

- Do not fix anything. Not a one-line path, not a typo in a playbook. File it.
- Do not file a finding that does not clear a stated bar. There is no
  "worth mentioning" tier.
- Do not file a decision as `open`.
- Do not file about issues that are merely open and unworked — a backlog is not a
  gap.
- Do not write a status file to `/Users/mbryzek/code/openclaw/…`. That path does
  not exist here; it is D4's own worked example, and a playbook that commits the
  defect it detects is worse than one that detects nothing.
- Do not run `dev queries top`, the invariants checks, or anything else that
  belongs to another producer. This one reads run history and issues.

## Report and close out

The durable home for this run's output is **this issue's timeline** — it is
machine-independent, it is where the findings are already linked, and it is what
ISS-503 concluded a producer's outcome should use instead of a file on one host's
disk. Put the report in the close-out comment:

- the window reviewed
- per detector: candidates considered, which cleared the bar, and **which did
  not, with the reason** — the rejections are the evidence the bar is doing work
- every issue filed, with its number and whether it went `open` or `needs_input`
- anything you deliberately routed to a comment on an existing issue instead

Also write a copy to `~/code/claude/plans/data/meta-review-<YYYY-MM-DD>.md` so the
next run can diff against it and see what is still unfixed a week later.

Then:

    dev issues status <n> --status fixed --url "<the plan file path, or the first issue filed>" --comment "<the report>"

A run that filed nothing closes out the same way, with a report that says what it
checked and why nothing cleared. That is the expected result most weeks.

## Inversion, before you file

This whole producer is a regret in six months if it files issues about issues,
nobody reads them, and the queue grows a tier of meta-work that never gets
claimed — at which point it has made the real signal harder to find, which is the
exact opposite of the point.

So, for each thing you are about to file: **would someone actually work this?** If
the honest answer is "probably not, but it is technically true", drop it. Filing
it does not make the system better; it makes the queue worse.
