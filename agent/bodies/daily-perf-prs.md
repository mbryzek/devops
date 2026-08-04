# Daily slow-route auto-PR

Find the routes that are slow for real end users and, for the worst ones that do
not already have a PR, investigate, fix, and open a draft-then-ready PR. Never
auto-merge. Small and reviewable: one route per PR. Doing nothing and reporting
why is the common, healthy outcome.

This is the automated form of the `/admin/integrations` fix: measure → root-cause
→ fix one thing → verify. Follow `~/code/CLAUDE.md` and the
`superpowers:systematic-debugging` skill.

## Tunables (change them here, not per run)

- `LOOKBACK_DAYS = 7`
- `MIN_VIEWS = 20` — ignore low-traffic routes; they are noise, not impact.
- `MAX_PRS_PER_DAY = 2` — hard cap per run, bounding cost and review load.
- `LEDGER = ~/code/claude/perf-ledger.md` — records terminal outcomes (see dedup).
- **Per-route p95 budget.** A route is slow only if its p95 exceeds its budget:
  - `/graphs/*` (matching `^/graphs(/|$)`) → **2000ms**. Graphs legitimately load a lot.
  - every other route → **500ms**.
  - Add categories here as needed rather than flattening to one threshold.

## Prerequisites — fail loudly

- A valid admin session for the `dev` CLI. Test with `dev slow-routes --limit 1`.
  If it prints `session expired - run 'dev login'`, STOP: report that the session
  needs refreshing and close this issue `--status needs_input`. Never attempt an
  interactive `dev login` in an unattended run.
- `gh` authenticated for mbryzek repos.

## 1. Fetch candidates

Run per app so member and admin are both covered:

    dev slow-routes --app member --days 7 --sort -p95 --limit 25
    dev slow-routes --app admin  --days 7 --sort -p95 --limit 25

Each row is `(app, route, views, p50, p75, p95, p99, ttfb)`. The command also
prints a ready-to-paste investigation prompt for its top row — reuse that framing.

**Filter** to real problems: compute `budget = 2000 if route matches ^/graphs(/|$)
else 500`, and keep rows where `views >= MIN_VIEWS` AND `p95 > budget`. A graph at
1200ms is fine; a normal page at 600ms is not.

**Rank** the survivors by over-budget user-time impact = `(p95 - budget) * views`,
so a page 1000ms over its budget outranks a graph 100ms over its much larger one.

An empty list means "no routes over budget" — report it and stop.

## 2. Dedup — skip anything already handled

For each candidate compute a stable identity:

- `slug` = route lowercased, `[` and `]` removed, every non-`[a-z0-9]` run → `-`,
  trimmed. e.g. `/insights/[insightId]` → `insights-insightid`.
- `branch` = `perf/<app>-<slug>`. **This branch name is the route's identity** —
  the same route always maps to the same branch.

A candidate is already handled, and is skipped, if EITHER:

1. A PR exists in ANY state for `<branch>` in a relevant repo — check the app's
   frontend repo AND platform, since the fix could land in either:

       gh pr list --repo mbryzek/platform      --head <branch> --state all --json number,state
       gh pr list --repo mbryzek/playbook-app  --head <branch> --state all --json number,state   # app=member
       gh pr list --repo mbryzek/playbook-admin --head <branch> --state all --json number,state  # app=admin

   Any hit skips it. That deliberately covers **open** (in progress), **merged**
   (already fixed) and **closed** (a human looked and declined) — never reopen a
   route someone rejected.
2. The route+app appears in `LEDGER` with a terminal status (`wont-fix`/`fixed`).

Take the top `MAX_PRS_PER_DAY` of what survives.

## 3. Fix each selected candidate, one PR each

1. `mkdir -p ~/code/ai/<short-name>` (≤19 chars — abbreviate the slug) and clone
   the repos you will likely touch (the app's frontend, platform, and a `devops`
   sibling for codegen). Branch every clone as `<branch>` off latest `origin/main`
   (`git fetch origin` first).
2. Investigate with `superpowers:systematic-debugging`. Attribution shortcut from
   the metrics: if `p75 ttfb` is a large share of `p75 load` it is **server side**
   (a slow platform endpoint or SSR `load` — instrument the endpoint and find the
   dominant call, as the `getAdminInvocations` fix did). If ttfb is small it is
   **client side** (hydration, bundle, an over-fetching client `load`).
   Instrument, drive an authenticated load, measure, find the single dominant
   cost, fix that.
3. Verify: the changed repo compiles and its tests / `npm run check` pass, and
   where feasible re-measure to confirm p95 drops. Scala tests run against this
   session's Dockerized database via the `session-db` skill — `claude-db start
   --app platform` — never Mike's local DB on `:5432`, and never a URL you did not
   get from `claude-db start`.
4. If investigation shows **no worthwhile fix** (already optimal, or it needs a
   product decision), open NO PR. Append to `LEDGER`:
   `<app> <route> | wont-fix | <one-line why> | <date>` so it is not
   re-investigated tomorrow, and move on.
5. Otherwise open the PR per CLAUDE.md: commit, push `<branch>`, `gh pr create
   --draft` with before/after numbers, then `gh pr ready`. Prefix the title with
   this issue's number: `ISS-<n>: <title>`. Cross-repo contract changes update
   every consumer on the same branch and rerun codegen. Append to `LEDGER`:
   `<app> <route> | fixed | PR <urls> | <date>`.

Never merge, never push to `main`, never force-push someone else's branch. Do not
report a Reviewable URL.

## 4. Write the status file the briefing reads

Write `/Users/mbryzek/code/openclaw/openclaw-workspace/data/daily-perf-prs-status.md`
with this machine-readable header at the very top — **the morning briefing parses
it** (item 15) and keys on both lines:

    Last run: <YYYY-MM-DD HH:MM ET>
    Status: <prs-opened | nothing-actionable | session-expired | error>

    <the human-readable summary: ranked candidate table with a handled/picked/
    below-threshold marker per row; per PR opened, the route, before→after p95 and
    the GitHub URL; any wont-fix ledger entries with their reason>

Use `Status: nothing-actionable` when nothing crossed the bar — the briefing skips
that case, which is the point. Use `session-expired` when `dev` needs a login.
No emojis.

## Guardrails / inversion

- Dedup is stateful across PR states, so a rejected route stays rejected and an
  in-flight one is not duplicated. The branch name is the single source of truth
  for "already handled".
- `MAX_PRS_PER_DAY` plus one route per PR keeps diffs small and review bounded.
- The per-route budget plus a volume floor stops this chasing pages that are slow
  only in absolute terms.
- A human disposes: everything lands as a ready PR; nothing merges itself.
- If a fix fails verification, do NOT open the PR — ledger it as
  `wont-fix | needs-human` and report it, rather than shipping something unverified.

## Closing out

Close this issue per CLAUDE.md — `dev issues status <n> --status fixed --url
"<PR URL>"` — pointing at the PR, or at the status file when the run was correctly
a no-op.
