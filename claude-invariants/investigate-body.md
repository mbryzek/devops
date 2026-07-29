# Investigating a failing invariant

The failure block above is the whole brief the CLI has. It is a SYMPTOM report,
not a diagnosis — nothing in it tells you whether the data is wrong, the process
that produces the data is wrong, or the invariant itself is wrong. Work that out
before you change anything.

Only this app's failures are yours. Another session may be working the other
apps in parallel; stay in your repo(s) and do not "helpfully" fix theirs.

## Orient

- Find each failing invariant's definition first — grep the invariant name in the
  app's repo — and read its exact predicate: what it asserts, what it scopes to,
  what it already excludes. Do NOT reason from the invariant's name. Names drift
  from their predicates, and a name that sounds obvious is how you end up fixing
  the wrong thing.
- The examples above are a sample, not the population. Re-run the check yourself
  (`dev invariants check --app <app> --all-examples`) and look at the whole set:
  do the rows share a tenant, a date range, a code path, a deploy boundary? A
  1-row failure and a 400-row failure usually have different causes.
- Read production state through the app's API and the read-only `dev` commands.
  NEVER connect to the production database, and never write to production.
- Anything you run locally goes against the session DB on `localhost:5433` (see
  the `session-db` skill). Never `localhost:5432` — that is Mike's dev DB.
- Durable records first. Prod pod logs do not survive the pod, so pull
  invocations, tasks, watermarks, and audit columns before you go looking for log
  lines that are probably already gone.

## Classify before you fix

Decide which of these it is, and say so explicitly in your PR or findings:

1. **Data corruption / a real bug upstream** — the invariant is right and
   something produced bad state. Fix the producer, not the receiver, and add a
   regression test that FAILS without your fix. Whether the existing bad rows
   need remediation is a SEPARATE decision: propose a reviewable migration, do
   not hand-patch rows.
2. **A stalled or never-run process** — the state is not wrong, it is missing,
   because a job, backfill, or approval step never completed. Find where it
   stalled and why nothing noticed. A silent stall is itself a bug worth fixing.
3. **The invariant is wrong or too broad** — the data is legitimately in this
   state (a test tenant, a deleted or inactive record, an intended edge case) and
   the predicate should exclude it. Fixing the invariant is a VALID outcome, not
   a cop-out — but justify it with evidence, and say what real breakage the
   narrowed predicate will now stop catching.
4. **Transient** — re-run before concluding this. If it clears on its own you
   still owe an explanation of why it was ever true; "it went away" is not a root
   cause. If it is genuinely transient and expected, consider a snooze
   (`dev invariants snooze <name> --app <app> --days N --reason "..."`) rather
   than leaving it to fail every day.

## Hard rules

- NEVER fabricate, backfill, or zero-fill data to make an invariant pass.
- NEVER change production behavior for the sole purpose of turning a check green.
- Invert before you commit: what would make this fix a regret in six months? If
  you are narrowing an invariant, what real defect does it now hide? If you are
  writing a migration, what happens when it runs twice?

## How to work

Follow `~/code/CLAUDE.md`. The parts that bite most often:

- Work in a NEW subdirectory under `~/code/ai/<short-name>` (≤19 chars). NEVER
  edit the repo checkouts under `~/code/` directly — clone what you need into the
  feature dir and use the same feature branch across every repo you touch.
- Branch off the latest `origin/main` (`git fetch origin` first), never off
  another feature branch.
- Write tests. Read the existing tests in each repo first to match their shape.
- A shared contract change (apibuilder spec, lib, DB column, config key) is a
  CROSS-REPO change: find and update every consumer on the same branch.
- When done: commit, push, open a DRAFT PR, then mark it ready. Rebase onto the
  latest `origin/main` and rerun codegen before the branch is final.
- Report the Reviewable URL, the PR URL, and the working directory.

If the conclusion is that NO code change is needed, write the findings to
`~/code/claude/plans/` instead of opening a PR, and explain how you ruled out the
other three categories above.

If something is ambiguous, make the most reasonable call, note the assumption,
and keep going — surface every judgment call at the end rather than stopping to
ask mid-task.
