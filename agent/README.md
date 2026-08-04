# `dev agent` — the autonomous dispatcher

Mac minis that pick up work as it arrives and drive each unit to a ready PR, with
nobody dispatching by hand. Design: `~/code/claude/plans/2026-08-03-agent-dispatcher-design.md`.

**`dev issues` is the only queue.** There is no job table and no second place to
look. Everything here exists to drain the open issue queue.

## What is in this directory

| File | What it is |
|---|---|
| `producers.yml` | The schedule registry. The only place a schedule lives — the platform records run history but has no notion of "due". |
| `bodies/` | The playbooks a producer ships with the issue it files (`issue.body_file`). Without one the claiming session gets `claude-issues/default-body.md` and does generic triage instead of the job the producer was written to schedule. |
| `instructions.md` | Part 1 of every session's prompt. Outcome protocol, the relaxed review gates, and the safety rules that are *not* relaxed. Reviewed like code. |
| `githooks/pre-push` | Enforces "an autonomous session may only write to `plans/` in `~/code/claude`". Injected into every session via `core.hooksPath`. |

## The commands

```
dev agent tick [--dry-run]        one shot; launchd runs it every 30s
dev agent status                  this machine: identity, live jobs, last tick
dev agent logs <issue> [--follow] tail one session's claude.log
dev agent pause | resume          kill switch — drains, claims nothing new
dev agent runners                 the fleet: capabilities, concurrency, last seen
dev agent producers               registry, last run, result, next due
dev agent runs [<key>] [--issue N] producer run history and lease attempts
dev agent refresh <issue>         re-open a fixed issue for rebase / review feedback
dev agent release <issue>         force-release a stuck lease
dev agent gc                      purge logs and workspaces per the retention table
```

`dev agent tick --dry-run` prints every decision a real tick would make and
executes none of them. It doubles as the provisioning smoke test on a new
machine: if it registers a runner, reads the producer registry, and reports its
capacity, the box is wired up.

## Provisioning a machine

Install the toolchain, then:

1. `gh auth login`
2. `dev auth ai provision` (or `dev auth ai set <token>`)
3. `cp launchd/com.bryzek.dev-agent.plist ~/Library/LaunchAgents/`
4. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bryzek.dev-agent.plist`

The first tick self-registers the machine on its `IOPlatformUUID` and the server
derives `max_concurrency` from the reported RAM. Nothing else is configured by
hand.

**Host prerequisites** — the full table, and why each one silently kills an
unattended machine, is in the XML comment at the top of the plist: auto-login,
FileVault (stays on, deliberately), sleep disabled, Docker Desktop at login, `gh`
+ `dev auth ai`.

## Where everything is written

One root, `~/Library/Logs/dev-agent/`. Nothing writes anywhere else.

```
tick/YYYY-MM-DD.log        one line per decision: phase, claims, reaps, timings
producers/YYYY-MM-DD.log   each producer run: key, result, duration
issues/ISS-<n>/
  prompt.md                exactly what was fed to the session on stdin
  claude.log               the session's full stdout
  exit_code                the wrapper's record of how it exited
  meta.json                issue, pid, slug, branch, timeout_at, outcome
```

Local state, all under `~/.platform/` and all of it a **cache**: `agent.identity`
(runner id + token), `agent-jobs/<issue>.json` (is this pid alive),
`agent-heartbeat`, `agent-notified.json`. Delete all of it and the cost is one
re-registration plus some orphaned processes whose leases expire within ten
minutes.

Retention (`dev agent gc`, daily at 4:00am as a producer): tick and producer logs
30 days; a terminal issue's directory 14 days; a failed or gave-up one 30 days —
the post-mortem window; workspaces deleted on success and after 7 days otherwise.

## Two phases, two locks

Phase A is **vitals** — runner heartbeat, lease heartbeats, and the 4-hour hard
timeout — and it always runs. Phase B is **work** — reap, producers, claim — and
it is skipped entirely when a previous tick still holds the lock.

Putting both under one lock inverts the system's own alarm: a slow Phase B would
block heartbeats on a perfectly healthy machine, tripping the offline invariant
and, worse, letting leases lapse so `expire_issue_leases` requeues work that is
still running. Locking is Ruby's `File#flock`; `flock(1)` does not exist on
macOS.
