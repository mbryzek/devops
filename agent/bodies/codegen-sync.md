# Sync generated code

Generated code — apibuilder clients and DAOs — drifts when a spec merges in one
repo and the repos that generate from it are not regenerated.
`dev codegen sync --check` is the detector and `dev codegen sync` is the fix;
your job is to run the first, stop if it is clean, and supervise the second if
it is not.

**This issue is filed unconditionally, every night, WITHOUT anyone having looked
first.** It is not evidence that anything is out of sync. Run the check before
you form any view of what is wrong, and expect most nights to be clean.

## 1. Check first — and stop here if it is clean

    dev codegen sync --check

It clones every codegen-consuming repo, regenerates each against the backends'
specs **as merged**, and diffs the result. It opens no PR and spawns no Claude.
Expect it to take minutes and several GB of clones; that is why it is no longer
a producer check and why you are the one running it.

Its verdict is its exit code — the same contract every producer check uses:

| Exit | Means | Do |
|---|---|---|
| 0 | every repo regenerated to no diff | **dismiss and stop**, below |
| 1 | real drift; the repos are named on stdout | section 2 |
| 2 | the check could not complete; nothing was concluded | section 3 |

Clean is the common outcome and it is a **successful run**, not a wasted one:

    dev issues status <n> --status dismissed --comment "dev codegen sync --check exited 0 — generated code is in sync in every repo. No PR needed."

Then stop. Do not open a PR, do not clone anything else, and do not go looking
for other work — this issue's whole scope is that one question.

`dismissed` and not `fixed` deliberately: a no-op run must leave a TERMINAL
issue. `fixed` and `deployed` are both non-terminal for producer dedup, so
closing this `fixed` would suppress tomorrow's run, and the next, until someone
clicked verify.

## 2. Drift found — resync

    dev codegen sync

The same sweep, with the PRs turned on: it regenerates each drifted repo on a
`codegen-sync-<timestamp>` branch, and where the regen alone does not compile it
runs a bounded Claude session in that clone to fix the build. One PR per repo.

Both commands work in their own throwaway directory, `~/code/ai/cgs.<run_id>`,
which the command creates, purges and owns. That is the tool's scratch space,
not a repo checkout and not this session's workspace — leave it to the command
rather than cloning anything yourself, and do not treat writing there as working
outside your workspace.

Then, per PR it opened:

1. **Read the diff.** This is the part the sweep cannot do. Generated files
   should be the only thing that changed; a hand-written file in the diff means
   the fix session edited something it should not have, and that is a finding to
   report here rather than a PR to mark ready.
2. A repo whose PR the sweep left as `needs_attention` did NOT get a clean
   regen. Say so on this issue with the error; do not force it ready.
3. Give each PR the issue prefix — the sweep names them off its commit message
   and cannot know this issue's number:

       gh pr edit <pr> --title "ISS-<n>: Sync regenerated apibuilder/DAO code (<repo>)"

4. `gh pr ready <pr>` for each one that is right.

Close out with the first PR's URL:

    dev issues status <n> --status fixed --url "<PR URL>"

List every repo and its PR (or its error) in the comment — a sweep that fixed
four repos and failed the fifth must not read as a clean run.

## 3. The check itself broke (exit 2)

Exit 2 says nothing was concluded — a clone failed, `api` failed, a backend
dropped out of the sweep. It is NOT evidence that generated code is in sync, and
it is not evidence that it is drifted either.

Read the sweep's output for the repo and the reason, and report it here. If the
cause is something you can fix inside this session (a transient clone failure
worth one retry), fix it and re-run the check from the top. If it needs a
decision or points at a real bug in `dev codegen sync`, close this issue
`--status needs_input` with the specific question, or file the bug separately
with `dev issues create --category bug --status open` and dismiss this one
naming that issue.
