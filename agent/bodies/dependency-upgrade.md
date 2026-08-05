# Nightly library dependency upgrades

This is a CONTAINER, not a unit of work. Nothing is claimed here and nothing is
implemented here: each child issue is one repo's upgrade, worked on its own
branch with its own PR.

The pipeline behind every child is `dev dependencies upgrade --app <repo>`:

- It clones the repo into a fresh workdir under `~/code/ai/dep-up.<MMDD>/` —
  nothing ever touches the checkouts under `~/code/<repo>`.
- It detects candidate bumps with `sbt dependencyUpdates` (sbt-updates injected
  via `--addPluginSbtFile`, so no repo commits the plugin), then applies the
  version policy and `lib/dependencies/denylist.yml`.
- It is **self-gating**: a repo that already has an open `dep-upgrade-*` PR is
  skipped, so a night that gets cut short is harmless — the next one resumes.
- It merges that repo's outcome into `dependencies-status.json` in the day's
  workdir. **The morning briefing reads that file** (the `bf-dependencies`
  generator takes the newest `~/code/ai/dep-up.*/dependencies-status.json` dated
  today), which is why all of a night's children share one workdir.

## Why an epic

The night is six independent runs — six clones, six suites, six PRs. As one
issue they shared one lease and one 4-hour budget, so a single slow repo took
the whole night with it and a failure in the fourth repo hid the first three. As
children each repo gets its own lease, retry, budget and outcome.

A repo whose previous night's issue is still open is deliberately NOT re-filed;
the rest still run.

## Verification

This epic advances to `deployed` on its own once every child is terminal, and it
is the single thing to verify for the night — verifying it verifies every child
with it. Review the PRs the children opened, then verify here.
