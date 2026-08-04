# Daily slow-query review

Review the platform's database query costs for the last 24 hours, find queries
worth fixing, prove the fix, and open a PR. If nothing crosses the bar, say so in
one line and stop — a quiet day is a valid outcome, and manufacturing a finding is
worse than silence.

**Orientation.** The platform is a Scala 3 / Play monolith on PostgreSQL 18,
hosted on DigitalOcean managed Postgres. Every query it runs is counted by
`util.QueryStats`, keyed by normalized SQL, and flushed every 6h into
`query_stats.query_samples` by `core.actors.QueryStatsActor`. Rows carry `calls`,
`total_ms`, `max_ms` and `call_site` — the Scala code that issued the query,
resolved once when the query first got hot. That last column is why the table
exists: production `pg_stat_statements` can tell you a query is expensive but not
which code issues it.

## 1. Rank by total time, not mean

    dev queries top --limit 25            # by total_ms
    dev queries top --limit 25 --by-mean  # individually slow, rarely run

Rank by `total_ms`. This is the single most important habit here: the worst query
ever found on this database had a 698ms mean, unremarkable next to a 6-second
dashboard query, and was the largest consumer on the instance only once multiplied
by 25,368 calls. Sorting by mean buries exactly the class of problem you are
looking for.

If `dev queries top` reports no query samples, that is a valid outcome — record it
as `Status: no-data` in the status file below and stop.

## 2. Decide what deserves investigation

Bar for a finding, any one of:

- over an hour of cumulative database time in 24h
- over 1000 calls with a mean above 500ms
- a query whose `total_ms` roughly doubled versus prior days in the table

Check that last one with a direct query rather than by eye —
`query_stats.query_samples` keeps history, so compare the same normalized `sql`
across `created_at` windows.

## 3. Get the plan, with buffers

Never diagnose from timings alone.

**Production database access is forbidden.** Use the local clone at
`localhost:5432/platformdb`, which holds production-shaped data — this is the one
deliberate exception to the session-DB rule, and it holds *only* because this step
is strictly READ-ONLY: `EXPLAIN` and `SELECT`, no writes, no `VACUUM`, no schema
changes. The moment you need to run a test or write anything, that goes to this
session's own Dockerized database (`claude-db start --app platform`, see the
`session-db` skill), never to `:5432`. Tests truncate; the clone is shared.

    EXPLAIN (ANALYZE, BUFFERS) <the query>;

**Judge by blocks touched, not by local milliseconds.** Local NVMe does a random
read in ~0.04ms; production network-attached storage takes ~0.5–1ms. A query
reading 43,840 blocks looks like 38ms locally and costs seconds in production.
Block count is what transfers between the two; wall clock is not. This is also why
"it's fast locally" is never evidence that something is fine.

The tell for a missing index is a large `shared read=` next to a small
rows-returned: scanning a whole table to hand back seventeen rows.

## 4. Prove the fix on the clone before writing anything

Create the candidate index (name it `tmp_claude_*` so it is obviously disposable),
re-run the `EXPLAIN`, and compare block counts. Then **drop it** and verify the
database is back exactly as you found it.

Fixes already tried against these queries that did **not** work — do not
re-litigate without new evidence:

- pushing a redundant `club_id` filter onto joins (3% improvement)
- a wide covering index carrying every column (no improvement, and it made another
  query worse by adding pages to traverse)
- extended statistics to correct a 4.7x row underestimate (plan unchanged)
- inverting a join to drive from the more selective side (it was not more selective)

## 5. Only then, write it up

Work in a new directory under `~/code/ai/<short-name>/` (≤19 chars), clone the
repo you need, branch from latest `origin/main`. Never edit repos under `~/code/`
directly.

Schema changes are hand-written SEM scripts in `platform-postgresql/scripts/`.
The filename timestamp **must sort after every already-released script** — check
`git tag` for the latest release and list its `scripts/` before choosing a name. A
script that sorts earlier than a released one is the standard way this goes wrong.

Include in the PR body: block counts before and after, call counts and cumulative
time from `dev queries top`, and why you rejected the alternatives you rejected.
Open it as a draft (`gh pr create --draft`, no `--base`), prefix the title with
this issue's number (`ISS-<n>: <title>`), then `gh pr ready`. Review happens in
Reviewable automatically — never report a Reviewable URL.

## Guardrails

- Never connect to the production database. The local clone is the only source of
  production-shaped data, and only for reads.
- Never deploy, never merge, never push to `main`.
- Never `VACUUM FULL` or otherwise mutate the shared local database without saying
  that you did.
- If a finding is a code change rather than an index — an N+1, OFFSET pagination,
  row-at-a-time inserts — describe it and stop. Do not restructure a processor
  unattended.

## 6. Write the status file the briefing reads

Write
`/Users/mbryzek/code/openclaw/openclaw-workspace/data/slow-query-review-status.md`
in exactly this shape. **The morning briefing parses it** (item 21) and keys on
the first two lines:

    Last run: <YYYY-MM-DD HH:MM> ET
    Status: <pr-opened | nothing-actionable | no-data | error>

    <the report, lead line first: whether anything crossed the bar; if yes the
    query, its call site, its cumulative cost, the before/after block counts and
    the PR link; if no, one line naming the top consumer and its cost so the trend
    stays visible on quiet days>

## Closing out

Close this issue per CLAUDE.md — `dev issues status <n> --status fixed --url
"<PR URL>"` — or point `--url` at the status file when nothing crossed the bar.
