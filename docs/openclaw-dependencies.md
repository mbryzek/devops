# Running `dev dependencies upgrade` every morning via openclaw

> **HISTORICAL.** The nightly run moved onto the devops agent (ISS-397): the
> `dependency-upgrade` producer in `agent/producers.yml` files an epic every
> night at 3:45am with one child issue per repo, and a claiming session runs
> `dev dependencies upgrade --app <repo>` for its own repo under a lease. The
> openclaw cron and the launchd plist are both gone — do not re-add either, or
> the open-PR gate becomes the only thing standing between you and duplicate
> runs. What follows describes the retired setup, kept for the flag values and
> the briefing wiring. Note that the bare `dev dependencies upgrade` in the cron
> command below no longer runs: every PR the pipeline opens is titled
> `ISS-<n>: Upgrade dependencies` (ISS-1104), and outside an agent session —
> which is what a cron is — the number has to come from `--issue`.

Two cron jobs on the openclaw gateway: one runs the pipeline overnight, one
delivers the morning summary. Use EITHER this OR the launchd plist
(`launchd/com.bryzek.dev-dependencies.plist`) — not both, or you'll get
duplicate runs racing on the open-PR gate.

Requires an operator-scoped session (run from your own terminal; agent tokens
lack `operator.read`/`operator.write`).

## Job 1 — the nightly run (3:00 AM)

```bash
openclaw cron add "dep-upgrade-nightly" \
  --cron "0 3 * * *" --tz America/New_York \
  --command '/bin/zsh -lc "mkdir -p ~/Library/Logs/dev-dependencies && ~/code/devops/bin/dev dependencies upgrade 2>&1 | tee -a ~/Library/Logs/dev-dependencies/$(date +%Y%m%d).log"' \
  --timeout-seconds 21600 \
  --no-output-timeout-seconds 7200 \
  --output-max-bytes 200000 \
  --announce --best-effort-deliver \
  --description "Nightly dependency upgrades: dev dependencies upgrade (verified PRs by morning)"
```

Why these values:
- `/bin/zsh -lc` — the gateway's `sh -lc` won't have nvm's node (`claude`),
  sbt, or gh on PATH; a zsh login shell matches your interactive environment.
- `--timeout-seconds 21600` (6h) — worst case is six repos serially, each up
  to a 90-minute Claude session; typical nights (few or no bumps) finish in
  well under an hour.
- `--no-output-timeout-seconds 7200` — during a Claude upgrade session the
  command is legitimately silent for up to ~90 minutes; 2h of silence means
  genuinely wedged.
- `--announce --best-effort-deliver` — the run's final output (the
  per-repo summary with PR URLs) lands in your last chat channel when it
  finishes; delivery failure doesn't fail the job.
- `tee` into `~/Library/Logs/dev-dependencies/<date>.log` keeps the same log
  location the launchd variant uses.

## Job 2 (optional) — tidy morning briefing (7:30 AM)

The 3 AM job's announce arrives whenever the run finishes (middle of the
night). If you'd rather get one clean message with your coffee:

```bash
openclaw cron add "dep-upgrade-briefing" \
  --cron "30 7 * * *" --tz America/New_York \
  --message 'Read the newest ~/code/ai/dep-up.*/dependencies-status.json (mtime, today only — say "no run happened" if none is from today). Summarize per repo: PR opened (give the GitHub URL and the matching https://reviewable.io/reviews/mbryzek/<repo>/<pr> link), in sync, held back (with denylist reason), skipped, or error. Lead with the PRs that need my review. Keep it short.' \
  --tools exec,read \
  --announce --best-effort-deliver \
  --description "Morning summary of last night's dependency-upgrade run"
```

## Operating it

```bash
openclaw cron list                      # see jobs + next fire times
openclaw cron run dep-upgrade-nightly   # trigger a run right now (debug)
openclaw cron runs dep-upgrade-nightly  # history of past runs
openclaw cron disable dep-upgrade-nightly
```

Notes:
- The pipeline is self-gating: a repo with an open `dep-upgrade-*` PR is
  skipped, so an extra manual `cron run` can't stack duplicate PRs.
- Machine-readable results: `dependencies-status.json` in that run's
  `~/code/ai/dep-up.<MMDD-HHMM>/` workdir (auto-purged by `dev aidirs prune`).
- Denylist for known-bad upgrades: `lib/dependencies/denylist.yml`.
