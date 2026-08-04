# Nightly library dependency upgrades

Run the dependency-upgrade pipeline and report what it did. The pipeline itself
is `dev dependencies upgrade`; this issue exists so the run has a lease, a
heartbeat, a retry and a run record instead of being a backgrounded process
nobody was watching.

## The one command

    cd ~/code && dev dependencies upgrade

That is the whole job. It is deliberately not something you reimplement:

- It clones each watched repo (platform, acumen, lib-util, lib-query, lib-cipher,
  lib-ai) into a fresh workdir under `~/code/ai/dep-up.<MMDD-HHMM>/` — nothing
  ever touches the checkouts under `~/code/<repo>`.
- It detects candidate bumps with `sbt dependencyUpdates` (sbt-updates injected
  via `--addPluginSbtFile`, so no repo commits the plugin), then applies the
  version policy and `lib/dependencies/denylist.yml`.
- It hands the allowed bumps for each repo to its own Claude session, which must
  end in a verified, review-ready PR.
- It is **self-gating**: a repo that already has an open `dep-upgrade-*` PR is
  skipped. That is what makes it safe to run every night, and what makes a night
  that gets cut short harmless — the next run picks up where this one stopped.
- It writes `dependencies-status.json` in its workdir. **The morning briefing
  reads that file** (via the `bf-dependencies` generator, which looks for the
  newest `~/code/ai/dep-up.*/dependencies-status.json` with today's date), so the
  run must be allowed to reach the end where the file is written.

Do not open PRs yourself, do not edit any repo directly, and do not re-run a repo
the pipeline already handled.

## Budget

An agent session is killed at 4 hours. The pipeline is serial across six repos
and most of them are usually in sync, so a normal night finishes well inside
that. If you are approaching the limit, let the pipeline finish the repo it is on
and report which repos it got through — the self-gating means tomorrow's run
resumes from there. Do NOT background the command and end early: a backgrounded
process outlives the lease, which is exactly the failure mode this migration
removed.

## Report and close out

Report the workdir path, the per-repo outcome from the summary table, and every
PR URL the run opened. Then close this issue per CLAUDE.md:

    dev issues status <n> --status fixed --url "<the most significant PR URL>"

If the run opened no PRs because everything was in sync, close it `fixed` with
the workdir's `dependencies-status.json` path as the URL and say so — a quiet
night is a successful run, not a failure.
