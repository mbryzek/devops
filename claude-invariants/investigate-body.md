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
- The examples above are capped at 100 per invariant by the server, so when the
  count exceeds that they are a sample and not the population. Compare each
  invariant's count against how many examples you were given before you
  generalize, and re-run the check yourself
  (`dev invariants check --app <app> --all-examples`) when you need them again:
  do the rows share a tenant, a date range, a code path, a deploy boundary? A
  1-row failure and a 400-row failure usually have different causes. Above 100,
  reconstruct the rest from the app's API rather than reasoning from the sample.
- Read production state through the app's API and the read-only `dev` commands.
  NEVER connect to the production database, and never write to production.
- Anything you run locally goes against this session's DB, whose host port is
  per container — use the `CONF_DB_DEV_URL` that `claude-db start` printed
  (`claude-db status` shows it again). See the `session-db` skill. Never
  `localhost:5432` — that is Mike's dev DB.
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

## The remediation you already have

For categories 1 and 2 there is usually a decision to make about the rows that
are already wrong. Reach for an existing `dev` command before you write a
migration or, worse, hand-patch rows — and never reach for one just to turn a
check green (see Hard rules).

**Every one of these that WRITES is human-only, and that is not a snag to work
around — it is the shape of the job.** The /dev console's mutations require
`platform_admin`, which does not admit the AI actor by design: reading the
console is how you form a theory, writing it is how a human acts on one. So
`tasks requeue`, `tasks delete` and `invariants snooze` all refuse for you,
before they send anything, and print the `dev issues handoff` line that parks the
exact invocation for a human. Run the command, paste the handoff it gives you,
fill in the title and body from what you actually found, and carry on — the
handoff is the tail of your investigation, not a failure of it. What you are
never short of is the evidence: every READ here is admitted to you, and the
refusal uses them (`tasks delete --discriminator` reports the live row count on
its way out, and tells you outright when the answer is zero and there is nothing
to hand over at all). Do not go looking for another route to the write; there
isn't one, and there is not meant to be (ISS-945).

- `dev tasks requeue [--app APP]` — force every failed async task to run now.
  The right move when the rows are fine and the work simply did not happen
  (category 2): a wedged lane, a job tier that crashlooped, a deploy that ate a
  batch. Recoverable, so it does not prompt.
- `dev tasks delete --id TASK_ID... [--app APP]` — remove specific task rows in
  any state. For the individual dead row you have already read and understood.
- `dev tasks delete --discriminator NAME [--app APP]` — remove every row for one
  queue. This is the fix for **`unknown_task_discriminators`**, which fires when
  a task type was retired without step 3: the enum value is gone, so
  `TaskDiscriminator.fromString` returns `None`, the dispatcher skips the rows,
  and they sit at `num_attempts = 0` forever. Nothing will ever run them; they
  are not recoverable work. The command takes a raw discriminator string
  precisely because the code no longer defines it. It prints the matching row
  count and asks first (`--yes` to skip, required when stdin is not a terminal).
  Confirm the type really was retired — grep the app for the discriminator and
  read the commit that removed it — before wiping a queue: a discriminator can
  also vanish by ACCIDENT (bad spec regen, wrong enum edit), and then the rows
  are real queued work and the fix is to restore the enum value instead.
- `dev invariants check --app APP --all-examples` — re-read the population
  yourself rather than reasoning from the capped sample above.
- `dev invariants snooze <name> --app APP --days N --reason "..."` — category 4
  only, and only with a reason that says when it will resolve itself.

Anything not covered by these is a code change or a reviewable migration, not a
manual write to production.

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
- Report the GitHub PR URL and the working directory. NEVER report a Reviewable
  URL — Mike navigates there from GitHub himself.

If the conclusion is that NO code change is needed, write the findings to
`~/code/claude/plans/` instead of opening a PR, and explain how you ruled out the
other three categories above.

If something is ambiguous, make the most reasonable call, note the assumption,
and keep going — surface every judgment call at the end rather than stopping to
ask mid-task.
