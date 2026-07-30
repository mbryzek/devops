## How this pipeline works

Every issue in this category is auto-filed by ONE piece of code: `BackfillHoldService` recording
that `ClubHistoryBackfillProcessor` refused to stamp `court_reserve.clubs.backfill_completed_at`,
because the club's initial Court Reserve history load left windows it will never fetch again. The
club is parked in onboarding `blocked` (reason `windows_exhausted`) and stays there — no engagement
scores, no "your data are ready" email — until a human resolves it. The issue body lists the exact
report types, windows, attempt counts, and last error type.

**This is an operational alert first and a bug report second.** The default outcome is not a PR:
it is a club unstuck. Decide which of these you are looking at before writing any code.

Fingerprint is `club-backfill-held:<club_id>` — one live issue per club, forever. A later driver
pass that finds the club still held records a recurrence rather than filing again, so a rising
occurrence count is the signal that the cause is systematic and worth a code fix.

### The two resolutions, both in playbook-admin

Open `/admin/clubs/<club_id>/integrations/court-reserve`. A held club shows a hold panel with:

- **Retry failed windows** — re-dispatches exactly the recorded blockers, bypassing the
  three-attempt cap, and returns the club to `backfilling`. The right move whenever the cause was
  transient (a worker died mid-batch, a proxy rung was blocked, Court Reserve was briefly down) or
  has since been fixed. Nothing about the cap or the stored attempt history is mutated, so a retry
  is always available and always bounded: the driver either completes cleanly on its next pass or
  holds again with the counts one higher.
- **Complete anyway** — set `Backfill completed at` by hand. This accepts the gap and lets
  onboarding finish. The right move when the data genuinely is not obtainable (the club's Court
  Reserve org never had that report, the window predates their account) and waiting helps nobody.
  An operator override is never revoked: a later pass will not un-complete the club.

### Diagnosing before you pick

Start from the failing invocations rather than guessing:

- Worker invocations for the club: `/admin/integrations/invocations?club_id=<club_id>`. Read the
  console log tail on a failed one — a "Worker timed out" rollup usually means the worker went
  silent mid-batch, not that the report itself is unfetchable.
- `court_reserve.worker_reports` for the club, filtered to the blocked report type and window:
  `error_type`, `errors`, and whether a later report ever covered the same window. A window only
  counts as uncovered when its failures were never covered by a later success, so a flaky window
  that eventually succeeded is not what you are looking at.
- `court_reserve.club_crawler_states` — a type marked `not_available` is excluded from the plan
  entirely and can never be a blocker, so a blocked type IS one the org has a page for.
- Transactions blockers are direct-fetch windows (`court_reserve.direct_fetch_windows`), not
  browser reports: they fail differently (no session, no captured export URL) and carry free-text
  `errors` rather than a classified `error_type`.

### Where the code lives

Repo `mbryzek/platform`, subproject `integrations/`:

- `app/integrations/courtreserve/processor/ClubHistoryBackfillProcessor.scala` — the driver. Plans
  the windows, decides complete-vs-hold, and owns `MaxWindowAttempts`.
- `app/integrations/courtreserve/services/BackfillHoldService.scala` — records the hold, blocks
  onboarding, and files THIS issue.
- `app/integrations/courtreserve/services/BackfillRetryService.scala` — the operator retry and its
  cap bypass.
- `app/integrations/courtreserve/services/BackfillWindowDispatcher.scala` — puts windows on the wire.
- `app/integrations/courtreserve/db/InternalCourtReserveClubsDao.scala` — `backfill_held_at` /
  `backfill_blockers` and the completion cascade the hold exists to stop.
- `app/integrations/courtreserve/db/InternalWorkerReportsDao.scala` — the coverage, attempt, and
  in-flight reads the plan is built from.

The worker side is repo `mbryzek/workers` (see the `worker` category's body for its layout); a
blocker whose `last_error_type` points at the browser or the proxy is usually a bug there rather
than in platform.

### When it IS a code fix

Recategorize to `bug` and work it normally if the evidence says the failure is systematic — a
report type whose export the parser cannot handle, a window shape Court Reserve rejects, a worker
that reliably dies on a particular report size. Say in the issue which club and which windows led
you there, retry the club once the fix ships, and close this issue out with the PR.
