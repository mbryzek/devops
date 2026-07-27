# Working this issue

The issue text above IS the brief — treat it the way you would treat the same
text typed straight into a Claude Code terminal. Any attachments are listed with
their URLs (or local paths); read them before you start.

Not every issue is a defect with an obvious fix. A `suggestion` is a member's
product feedback, and a `feature`/`improvement` may need a product call before
any code is written. Work out what the issue actually is FIRST:

- It is a defect in one of the pipelines with its own orientation (`graphs`,
  `worker`, `insights`) → say so in your PR, and read that pipeline's body file
  under `~/code/devops/claude-issues/` before digging in.
- It is buildable as described → build it.
- It needs a human decision (product scope, a tradeoff only Mike can call, or a
  question for the submitter) → do NOT guess. Close it with
  `--status needs_input --comment "<what you need decided or asked>"`.
- It is not actionable, or is already fixed → `--status dismissed` (or
  `needs_input`) with the reason.

**Everything you write on an issue is an INTERNAL note to the team.** It is
never a reply to the club or member who filed it, so do not address them
("Love this idea…", "Two questions for you…") — write it to Mike. The server
rejects a shared comment from an automated actor, and nothing internal is ever
quoted to the submitter. When the submitter genuinely needs to be asked
something, say plainly what should be asked; Mike writes and shares the
customer-facing reply from playbook-admin.

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
