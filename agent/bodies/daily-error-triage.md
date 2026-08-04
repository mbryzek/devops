# Daily error / stability triage

Find the single highest-leverage production error or stability pathology in the
platform from live logs and NewRelic, root-cause it in the code, and ship ONE PR
that fixes it properly.

"Pathology" means anything actively hurting the running system: unhandled
exceptions, crash/restart loops, dead-lettered or stuck tasks, failing invariants,
error-level log floods, OOM/heap pressure, request failures. **Do not limit
yourself to memory/OOM** — that is one class among many. Rank all of them and fix
the top one.

Reference exemplar of the output this loop should produce: platform PR #1290
("Task dispatcher self-heals orphaned discriminators instead of crash-looping").
That run found 1,576 TaskActor crash-restarts over 3 days from a removed
processor, root-caused it to a removed enum/processor with orphaned rows, and
shipped a self-healing fix with tests and rescoped invariants. Match that bar:
real root cause, structural fix, tests, invariants updated so it cannot silently
recur.

## Access

- **NewRelic NerdGraph**: account `7724695`, endpoint
  `https://api.newrelic.com/graphql`. Use the `newrelic` CLI if it is configured;
  otherwise take the API key from Mike's environment
  (`eval "$(~/code/devops/bin/env --app platform --env production --format sh)"`).
  **Never paste an API key into a file, a commit, or a PR body.**
  Entities: `platform-web` (web tier), `platform-job` (job/actor/task tier),
  `platform-worker` (workers). There is **no entity named `platform`** — a query
  filtering on it returns `[]`, which reads exactly like "no errors" and is a
  false all-clear. Sanity-check first with
  `SELECT count(*) FROM Log SINCE 3 hours ago FACET entity.name` so an empty
  result is never mistaken for a healthy one.
- **Never touch the production database.** Diagnose from logs and NewRelic only.
  If you need DB state, use the admin API — never a direct prod connection.
- **Invariants**: `dev invariants check --app platform` surfaces failing platform
  invariants (`tasks_dead_lettered`, `unknown_task_discriminators`,
  `tasks_not_completed_in_12_hours`, …). These are curated signals — check them
  first; a firing invariant is often the top pathology already named for you.

## How to identify the top priority

Treat prior-session memory as a hypothesis, not a conclusion — yesterday's hotspot
may have shipped. Always re-derive from live data.

1. **Survey what already shipped** so you do not repeat work:

       gh -R mbryzek/platform pr list --state merged --limit 25 --search "merged:>=$(date -v-7d +%Y-%m-%d)"
       gh -R mbryzek/platform pr list --state open --limit 25

   Read `~/.claude/projects/-Users-mbryzek-code/memory/project_*.md` and
   `reference_*.md` for in-flight notes on known pathologies.

2. **Check failing invariants first** — they are pre-triaged.

3. **Rank error-level log volume** across tiers, then drill into the loudest:

       SELECT count(*) FROM Log WHERE entity.name LIKE 'platform%'
         AND level IN ('ERROR','WARN') SINCE 24 hours ago FACET message, entity.name LIMIT 50

       SELECT count(*) FROM Log WHERE entity.name LIKE 'platform%'
         AND (message LIKE '%Exception%' OR message LIKE '%error.%' OR error.class IS NOT NULL)
         SINCE 24 hours ago FACET error.class, entity.name LIMIT 40

4. **Detect crash/restart loops** (the #1290 class). An actor or process failing
   repeatedly is far more urgent than its raw count suggests:

       SELECT count(*) FROM Log WHERE entity.name LIKE 'platform%'
         AND (message LIKE '%OneForOneStrategy%' OR message LIKE '%restart%'
              OR message LIKE '%Undefined processor%' OR message LIKE '%supervis%'
              OR message LIKE '%CrashLoop%')
         SINCE 3 days ago FACET message, entity.name TIMESERIES LIMIT 40

5. **Check heap/OOM as one facet** (the JVM emits `JvmMemoryMetrics` every minute;
   `Heap pressure detected` at WARN). Only chase it if it outranks the error and
   crash signals.

6. **Score and pick ONE.** Rank by: is it a loop (unbounded churn) > is it a
   firing invariant > error volume × recency > user-facing request failures >
   heap. A low-count-but-looping-forever signal outranks a high-count-but-benign
   warning.

7. **Read the code — do not skip this.** Drill into the loudest logger and host
   for the chosen pathology, then read the actual code path. Derive the fix from
   the code, not from the log message.

8. **Inversion before committing:** "What would make this a regret in 6 months?
   What invariant am I assuming that is not enforced? How could this fix silently
   break in prod?" If the fix is a knob or a swallow-the-error band-aid, find the
   structural change instead. This loop ships root-cause fixes, not suppressions.
   When you fix a recurring failure, make sure a test guards it AND an
   invariant/alert would catch a recurrence.

## How to ship

Follow CLAUDE.md exactly:

- A new `~/code/ai/<≤19-char-name>/` directory, fresh clone of the relevant repo
  (`git@github.com:mbryzek/<repo>.git`), branched off `origin/main` after
  `git fetch origin`. Never edit a checkout under `~/code/` directly.
- Read the relevant `~/code/claude/rules/*.mdc` before writing code — especially
  `scala.pattern.matching.mdc` (no wildcard `case _`),
  `scala.dao.task.queueing.mdc` if touching tasks, and `database.general.mdc`
  (never hand-write DDL).
- Write tests. DRY and high level; read the existing tests in the area first.
  Reproduce the failure in a test BEFORE fixing it where feasible.
- Compile and run the targeted specs against **this session's** Dockerized
  database (`session-db` skill) — never Mike's local DB on `:5432`. Export the URL
  in the SAME shell call as sbt, because env does not persist across calls:

      eval "$(~/code/devops/bin/claude-db start --app platform | grep '^CONF_DB_DEV_URL=' | sed 's/^/export /')" && sbt 'Test/compile'

  Verify a POSITIVE pass signal ("All tests passed") — never infer green from the
  absence of a failure, and never pipe the command through `tail`.
- If any apibuilder or DAO spec changed, rerun codegen (`api` regenerates both in
  one pass) and fix every downstream consumer on the same branch.
- Commit, push, `gh pr create --draft` (no `--base`; never stack PRs), then
  `gh pr ready <pr>`. Prefix the title with this issue's number: `ISS-<n>: <title>`.
- Rebase onto latest `origin/main`, rerun codegen if specs changed, fix any drift,
  and force-push with `--force-with-lease` after fetching.
- Review happens in Reviewable, which every open PR gets automatically. Do not run
  the old `code-reviewer` agent and `code-review` skill rounds as gates, and
  **never report a Reviewable URL** — Mike navigates there from GitHub himself.

## Report and close out

Report, in this order: the GitHub PR URL (marked ready), the working directory,
a three-line summary (the pathology with the count/window that ranked it top, the
root cause, the fix), and a short "Decisions & assumptions" list.

Also write a structured status to `~/code/claude/plans/data/daily-error-triage.md`
(create the directory if needed): the date, the top pathology chosen with the
runners-up you passed over and why, and the PR link — or "no PR — nothing above
the bar today" with the ranked signals you saw. That file is what stops the next
run repeating this one's work.

Then close this issue: `dev issues status <n> --status fixed --url "<PR URL>"`,
or `--url` the status file when nothing was above the bar. A clean "nothing above
the bar" report on a genuinely healthy day is a successful run.

## Do not

- Do not limit the search to OOM/memory — rank all error classes.
- Do not repeat a fix that already shipped or is open as a PR.
- Do not swallow or suppress errors as the "fix".
- Do not commit to main, pass `--base`, or stack PRs.
- Do not add backwards-compat shims, `@unused` annotations, `Thread.sleep`,
  wildcard pattern matches, or hand-written DDL.
- Do not stop early because you could not decide. One shipped PR per run when
  anything is above the bar.
