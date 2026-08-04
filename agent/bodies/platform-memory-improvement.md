# Daily platform memory / OOM improvement

Identify the single highest-leverage improvement to reduce memory usage or prevent
OOM in the platform app, using NewRelic data and the instrumented log statements
already in the codebase. Design it, implement it, and open a PR.

**Expect no fire.** Acute OOM has been out since 2026-06-26: the governor does not
fire and both tiers idle around 15-20% of their heap. So the usual honest finding
is "no acute pressure", and the work is **latent-path hardening** — finding a path
whose memory is bounded only by luck (an unbounded queue, an unbounded
accumulation, a table that grows forever feeding an in-heap rollup) and giving it a
real bound before it becomes a fire. Do not manufacture a hotspot out of a healthy
graph to justify a PR: say the heap is healthy, then go bound something that is
currently unbounded. A good target names the invariant it enforces.

## Access

NewRelic account `7724695`. Use the `newrelic` CLI if it is configured; otherwise
take the API key from Mike's environment
(`eval "$(~/code/devops/bin/env --app platform --env production --format sh)"`).
**Never paste an API key into a file, a commit, or a PR body.**

## How to identify the top priority

Treat memory from a prior session as a hypothesis, not a conclusion — yesterday's
hotspot may have shipped. Always re-derive from live data.

1. Survey what already shipped so you do not repeat work:

       gh -R mbryzek/platform pr list --state merged --limit 25 --search "merged:>=$(date -v-7d +%Y-%m-%d)"

   Read `~/.claude/projects/-Users-mbryzek-code/memory/project_*.md` for in-flight
   OOM notes.

2. Pull current heap pressure from NewRelic. **There is no entity named
   `platform`** — the two deployables report separately as `platform-web` (~2.8 GB
   heap) and `platform-job` (~9.8 GB heap), so every query must filter on those
   names. A query using `entity.name='platform'` returns `[]`, which reads exactly
   like "no heap pressure": a false all-clear. Sanity-check the connection first
   (`SELECT count(*) FROM Log SINCE 3 hours ago FACET entity.name`) so an empty
   result is never mistaken for a healthy one.

   The platform emits `JvmMemoryMetrics` log lines every minute. The fields are
   embedded in the message string, not as top-level attributes, so `aparse` is
   required (`SELECT max(heapPercent)` returns nothing). Prefer the **delta**
   fields: `gcCountDelta` / `gcTimeMsDelta` are per-minute windows, whereas the
   cumulative `gcCount` / `gcTimeMs` are JVM-lifetime totals that only climb and
   are unactionable (see the comment in `JvmMemoryMetricsActor`).

       SELECT count(*) FROM Log WHERE entity.name IN ('platform-web','platform-job')
         AND message LIKE '%Heap pressure detected%'
         SINCE 24 hours ago FACET entity.name, hostname LIMIT 30

       SELECT max(numeric(aparse(message, '%heapPercent: *,%'))) AS max_pct,
              max(numeric(aparse(message, '%gcTimeMsDelta: *,%'))) AS max_gc_ms_per_min,
              max(numeric(aparse(message, '%oldGenUsedMb: *,%'))) AS max_old_gen,
              max(numeric(aparse(message, '%heapUsedMb: *,%'))) AS max_used,
              max(numeric(aparse(message, '%heapMaxMb: *,%'))) AS heap_cap
         FROM Log WHERE entity.name IN ('platform-web','platform-job')
         AND message LIKE '%JvmMemoryMetrics%'
         SINCE 12 hours ago FACET entity.name, hostname LIMIT 30

   `oldGenUsedMb` is the one to watch: the old-gen floor — what survives a Full GC
   — is what actually causes OOM, whereas a high `heapPercent` is often just eden
   filling between collections.

3. For the hottest host, find the dominant logger and read its instrumented batch
   and phase logs (`FACET logger.name`, then the recent messages for that logger).

4. Cross-check with WARN-level pressure to confirm the hotspot is current and not
   a stale signal.

5. **Read the relevant code.** Do not skip this — derive the fix from the code, not
   from prior memory. Confirm the structural cause matches the log/NR pattern.

6. Inversion before committing: "What would make this a regret in 6 months? What
   invariant am I assuming?" If the answer is "this is just a parallelism knob",
   look for the structural change instead. Band-aids are not what this loop is for.

## How to ship

Follow CLAUDE.md exactly:

- A new `~/code/ai/<≤19-char-name>/` directory, fresh clone of the relevant repo
  (`git@github.com:mbryzek/<repo>.git`), branched off `origin/main`. Never edit a
  checkout under `~/code/` directly.
- Read the relevant `~/code/claude/rules/*.mdc` before writing code, especially
  `scala.pattern.matching.mdc` (no wildcard matches).
- Write tests. DRY and high level; read the existing tests in the area first.
- Compile and run the targeted specs against **this session's** Dockerized
  database (`session-db` skill) — never Mike's local DB on `:5432`, and never a URL
  you did not get from `claude-db start`. Export it in the SAME shell call as sbt,
  because env does not persist across calls:

      eval "$(~/code/devops/bin/claude-db start --app platform | grep '^CONF_DB_DEV_URL=' | sed 's/^/export /')" && sbt 'Test/compile'

- Commit, push, `gh pr create --draft` (no `--base`, never stack PRs), then
  `gh pr ready <pr>`. Prefix the title with this issue's number:
  `ISS-<n>: <title>`. Review happens in Reviewable, which every open PR gets
  automatically — do not run the old `code-reviewer` agent and `code-review` skill
  rounds as gates, and never report a Reviewable URL.
- Rebase onto latest `origin/main`, rerun codegen if any apibuilder or DAO spec
  changed (`api` regenerates both in one pass), fix any drift, and force-push with
  `--force-with-lease` after fetching.

## Write the status file the briefing reads

Write
`/Users/mbryzek/code/openclaw/openclaw-workspace/data/platform-memory-improvement.md`.
**The morning briefing's Open PRs generator reads it** (`scripts/briefing/gen-prs.md`),
so keep exactly one of these shapes:

    Last run: <YYYY-MM-DD>
    Status: PR opened
    PR: <full GitHub PR URL>
    Dir: <feature directory path>
    Summary: <one sentence describing what changed>

    Last run: <YYYY-MM-DD>
    Status: No action
    Reason: <brief explanation>

    Last run: <YYYY-MM-DD>
    Status: Error
    Detail: <error summary>

## Closing out

Close this issue per CLAUDE.md — `dev issues status <n> --status fixed --url
"<PR URL>"` — or point `--url` at the status file on a `No action` day.

## Do not

- Do not repeat a fix that already shipped. Verify the PR is not merged before
  designing.
- Do not commit to main, pass `--base`, or stack PRs.
- Do not add backwards-compat shims or `@unused` annotations.
- Do not use `Thread.sleep`, wildcard pattern matches, or hand-written DDL.
- Do not stop early because you could not decide. Pick the best hypothesis the
  data supports and ship it.
