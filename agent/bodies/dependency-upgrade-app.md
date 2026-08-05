# Dependency upgrades: {child}

Upgrade the library dependencies of **{child}** and report what happened. One
repo, one PR. This issue exists so the run has a lease, a heartbeat, a retry and
a run record instead of being a backgrounded process nobody was watching.

## The one command

    cd ~/code && dev dependencies upgrade --app {child}

That is the whole job, and it is deliberately not something you reimplement:

- It clones {child} into a fresh workdir under `~/code/ai/dep-up.<MMDD>/`.
  Nothing ever touches `~/code/{child}`.
- It detects candidate bumps with `sbt dependencyUpdates` and filters them
  through the version policy and `lib/dependencies/denylist.yml`.
- It applies the allowed bumps, verifies the suite, and ends in a review-ready
  PR — or reports that the repo is in sync.
- It is self-gating: if {child} already has an open `dep-upgrade-*` PR it stops
  and says so. That is a SUCCESSFUL run, not a failure — merge or close that PR
  and the next night picks the repo up.
- It merges {child}'s outcome into `dependencies-status.json` in the day's
  workdir, which the morning briefing reads. Let it run to the end.

Do not edit `~/code/{child}` directly, do not open a second PR by hand, and do
not upgrade any other repo — the sibling children of this epic own those.

## Budget

An agent session is killed at 4 hours; one repo finishes well inside that. If a
bump cannot be made green with reasonable effort, the pipeline reverts that bump
only and records it under "Deferred upgrades" with a ready-to-paste denylist
entry — do not fight it past that point.

## Report and close out

Report the workdir path, this repo's outcome, and the PR URL if one was opened:

    dev issues status <n> --status fixed --url "<PR URL>"

If {child} was in sync or was skipped because a `dep-upgrade-*` PR is already
open, close it `fixed` anyway with that PR's URL (or the workdir's
`dependencies-status.json` path) and say which — a quiet repo is a successful
run. Do NOT mark this issue `verified`: its epic is what gets verified.
