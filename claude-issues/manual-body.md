# Working a hand-filed issue

This issue was filed from the laptop with `dev issues create`, so the body above
IS the brief — treat it the way you would treat the same text typed straight into
a Claude Code terminal. Any attached files are listed with their local paths;
read them before you start.

## How to work

Follow `~/code/CLAUDE.md`. The parts that bite most often:

- Work in a NEW subdirectory under `~/code/ai/<short-name>` (≤19 chars). NEVER
  edit the repo checkouts under `~/code/` directly — clone what you need into the
  feature dir and use the same feature branch across every repo you touch.
- Branch off the latest `origin/main` (`git fetch origin` first), never off
  another feature branch.
- Write tests. Read the existing tests in each repo first to match their shape.
- A shared contract change (apibuilder spec, lib, DB column, config key) is a
  CROSS-REPO change: find and update every consumer on the same branch.
- When done: commit, push, open a DRAFT PR, then mark it ready. Rebase onto the
  latest `origin/main` and rerun codegen before the branch is final.
- Report the Reviewable URL, the PR URL, and the working directory.

If the brief is ambiguous, make the most reasonable call, note the assumption,
and keep going — surface every judgment call at the end rather than stopping to
ask mid-task.
