## How this pipeline works

This category covers the async/background workers — auto-filed by the daily log review. The
Court Reserve sync is by far the largest of them, so most issues here are about it; other
background jobs land here too, and the same "read the evidence, reproduce from a fixture, fix
the root cause" approach applies.

Court Reserve is ClubAid's upstream club-management system. Nothing is queried live: a browser
worker downloads each report as an Excel export, the platform converts and parses it, and every
dashboard number downstream comes from those parsed rows. Court Reserve issues are almost
always "the data is wrong/missing/stale", and the bug lives at one of these stages:

- **Scraper**: repo `mbryzek/workers` (clone `git@github.com:mbryzek/workers.git`; renamed from
  `court-reserve-workers`, so old PR links still say the old name). TypeScript + Patchright
  (Chromium), run as a Node HTTP service on k8s — NOT a Cloudflare Worker. One
  `src/tasks/sync-<report>.ts` per Court Reserve report (members, courts, audit, event-summary,
  transactions, reservations, events, event-registrations), dispatched by `src/batch.ts`
  `runReport`. Each task downloads an xlsx (`clickAndCaptureXlsx`,
  `captureViaPrintExcelButton`, `captureXlsxFromTrigger`) and ships the raw bytes to the
  platform.
- **Ingest + parse**: repo `mbryzek/platform`, subproject `integrations/`, under
  `app/integrations/courtreserve/`. `XlsxToCsvConverter` turns the upload into CSV; the
  `Csv*Parser`s in `csv/` parse it; processors in `processor/` (`ProcessUploadProcessor`,
  `ProcessCsvProcessor`, `ProcessWorkerReportProcessor`, ...) drive the flow. Contracts:
  `spec/court-reserve*.json`; tables: `dao/psql/court_reserve.*.sql` (crawler state in
  `court_reserve.club_crawler_states`, uploads in `court_reserve.uploads`, worker traffic in
  `court_reserve.worker_requests` / `worker_reports`).
- **Coverage**: gap scanning (`gapscan/`, `processor/GapScan*`) finds and re-requests date
  ranges the crawl missed. A "missing days" issue is usually a gap-scan or crawler-state
  question, not a parser one.
- **Where these issues come from**: the daily log review
  (`processor/DailyLogReviewProcessor` + `logreview/`) reads the day's runs, groups findings by
  root cause (`LogReviewGrouper`), and files them here automatically via `LogReviewIssueSync`
  under a stable `fingerprint`. That is why most of these have no club and a high
  `occurrence_count`.

## Decoding the issue

- **Auto-filed issues carry their own research.** The body is built by
  `logreview/IssueBody.scala` and mirrors the daily digest email: report kind, summary, a
  `[day N]` tag when it has recurred, affected clubs, an evidence snippet, and — for actionable
  bugs — an AI fix prompt with concrete investigation steps. START from that prompt; it names
  the code paths.
- **`occurrence_count` > 1 means it recurs daily.** The tracker dedups on `fingerprint`:
  a recurrence bumps the count and adds a timeline comment rather than filing a new issue.
  A high count means every day since it was filed is still broken — treat it as ongoing, not
  historical, and prefer the root-cause fix over a one-off repair.
- **Evidence snippets are truncated logs.** Confirm the failure in the real data before
  theorizing: local session DBs are schema-only (no prod rows) and you must NEVER touch the
  production DB. Reproduce from the parser + a fixture built from the snippet.
- Distinguish the three failure shapes before fixing: the scraper never got the export
  (`workers`), the export arrived but parsed wrong (`csv/`), or it parsed fine but coverage is
  incomplete (`gapscan/`).

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first
   (especially `scala.*.mdc` and `database.general.mdc`).
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-worker-<date>`);
   clone `platform` (plus `workers` if the fix is in the scraper). Never edit `~/code/platform`
   or `~/code/workers` directly.
3. Group related issues into one branch/PR — findings grouped under one fingerprint are one
   root cause and get one fix.
4. Verify: a scoped `sbt` spec that FAILS without your fix (parser bugs get a fixture built
   from the issue's evidence snippet); `npm run build` + the task's own tests in `workers`.
   Use the Docker session DB (`~/code/devops/bin/claude-db start`), never Mike's `:5432` and
   never production.
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
