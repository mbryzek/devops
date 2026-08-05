# `dev agent` — the autonomous dispatcher

Mac minis that pick up work as it arrives and drive each unit to a ready PR, with
nobody dispatching by hand. Design: `~/code/claude/plans/2026-08-03-agent-dispatcher-design.md`.

**`dev issues` is the only queue.** There is no job table and no second place to
look. Everything here exists to drain the open issue queue.

## What is in this directory

| File | What it is |
|---|---|
| `producers.yml` | The schedule registry. The only place a schedule lives — the platform records run history but has no notion of "due". The tick pulls this checkout itself, so one push reaches every machine. |
| `bodies/` | The playbooks a producer's issue POINTS AT (`issue.body_file`) — see "One copy of the plan" below. Without one the claiming session gets `claude-issues/default-body.md` and does generic triage instead of the job the producer was written to schedule. A `type: epic` producer shares one playbook across its children, with `{child}` substituted per child. |
| `instructions.md` | Part 1 of every session's prompt. Outcome protocol (including the close-out contract: a session files what it WORKED AROUND before it closes out), the relaxed review gates, and the safety rules that are *not* relaxed. Reviewed like code. It is also why a playbook in `bodies/` never restates any of that — reaching every session, including the next playbook's, is what this file is for. |
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
dev agent maintenance             this machine's housekeeping: gc + aidirs/docker prune
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

`agent-maintenance` joins that list: when this machine last ran its own
housekeeping, and how it went.

Retention (`dev agent gc`): tick and producer logs 30 days; a terminal issue's
directory 14 days; a failed or gave-up one 30 days — the post-mortem window;
workspaces deleted on success and after 7 days otherwise.

## Housekeeping is runner-local, not a producer

`agent gc`, `aidirs prune` and `docker prune` run once a day inside the tick, on
each machine's own cadence, with **no server run and no lock** (ISS-520,
`lib/agent/maintenance.rb`). They used to be producers, and that was wrong in a
way that only showed up with more than one runner: every producer runs behind a
fleet-wide daily compare-and-set, so exactly ONE machine per day won the right to
delete *its own* logs, feature dirs and images. The other N-1 never pruned
anything, silently, until a disk filled — which kills Docker and then surfaces as
unrelated spec failures on the box nobody is watching.

A producer FILES work and its output is an issue, so deduplicating it across the
fleet is the entire point. This DOES work and its output is free disk on the
machine that ran it, so there is nothing to deduplicate.

Two triggers: the daily **cadence**, and **disk pressure** — under 50GB free it
runs immediately with shorter windows (feature dirs and images to 1 day), subject
to an hour's cooldown so a machine that is genuinely full does not prune on a
loop. Nothing here talks to the platform: if the platform is unreachable for a
week every machine still prunes, because the moment you most need headroom is the
moment things are already broken.

What the platform does own is NOTICING that a machine stopped. Failures ride the
existing error channel (`Agent::Errors`, sources `agent_gc` / `aidirs_prune` /
`docker_prune`, escalating at 3 in a row), and the registry report carries
`last_maintenance_at` plus this machine's headroom — because an error log can
only report a run that broke, never one that never happened. The
`agent_runner_maintenance_stale` invariant is what files a single issue naming
any live runner that has gone quiet or is out of headroom.

## One push reaches the fleet

Phase A runs `git pull --ff-only origin main` in this checkout before it does
anything else, so changing a producer's schedule is a devops PR and nothing more —
no logging into each machine. `--ff-only` because a diverged checkout must stop
rather than merge, and a failed pull is reported, never fatal: the machine keeps
running the code it has. A pull that changes tick code takes effect on the NEXT
tick, which is safe precisely because the tick is one shot.

A machine whose pull is failing is otherwise indistinguishable from a healthy
one — same heartbeat, same runs — which is why each runner also reports what it
reads: every producer, its cadence, the next-due moment it computed, and the
devops sha it all came from (`PUT /agent/registry/:runner_id`). Git stays the
system of record; the platform holds *reports about* git and never evaluates a
schedule. Comparing those reports is what would make three things visible that
run history alone cannot show: a producer that is **overdue**, runners on
**different devops shas**, and a producer **no live runner schedules** at all.
Reported on a sha change (so a push shows the tick after it lands) and otherwise
on the heartbeat cadence, since next-due moves as producers run.

**What actually alarms today, as of ISS-505.** The report is stored and nothing
compares it: `AgentInvariants` covers heartbeat staleness only, there is no
sha-skew invariant, and there is no `/admin/agents` page (an earlier version of
this file claimed there was; ISS-521 builds one). What does alarm is the CAUSE
rather than the symptom — a runner only falls behind because its
`git pull --ff-only` stopped landing:

| Why the checkout is stale | What reports it |
|---|---|
| Pull fails repeatedly (network, credentials, diverged) | `Agent::Errors` counts consecutive failures; the third notifies and files a bug issue (ISS-511) |
| Working tree dirty, or on a branch other than `main` | Nothing — a benign skip, deliberately left alone. On an unattended mini it is silent forever, so a claim that resolves a playbook says so **on that issue** (`Tick#checkout_staleness_reason`) |
| Machine is dark | `agent_runner_heartbeat_stale` |

What remains unbuilt is the cross-fleet comparison — one runner cannot see that
it is the odd one out. Worth building on `agent_runner` rather than on
`agent_reported_registry`, which ISS-526 deletes.

## One copy of the plan, and it is the current one

A producer files a **pointer** to its playbook, never a copy of it (ISS-505). The
filed body carries the playbook's heading and opening paragraph, a ``Playbook:
`agent/bodies/x.md` `` line and a permalink; the claiming runner reads the
procedure off its own checkout and hands it to the session.

Copying froze it. An issue filed on Friday and claimed on Tuesday ran Friday's
procedure, and every improvement pushed to `bodies/` in between applied to
nothing already in the queue — which defeats the reason these are nightly
producers at all. Resolution happens at CLAIM time, not file time: pinning a sha
when the issue is filed would recreate the snapshot with extra steps.

Three things fall out of that and none of them is optional:

- **The runner records what it read** — `Playbook: agent/bodies/x.md @ <sha>`
  plus the permalink, as the issue's first comment. That is what keeps a run
  reproducible after the file changes, and it is the audit trail for the failure
  this design invites: a runner on a stale checkout reading last month's
  playbook. When this machine's own `git pull --ff-only` is failing, the comment
  says so outright rather than leaving the skew to be spotted by comparing
  runners in `agent_reported_registry`.
- **A pointer that does not resolve is a hard stop** — no session, and the issue
  goes to `needs_input`. Never a fallback: ISS-360 is a week of a producer doing
  generic triage because its playbook was missing and nothing said so.
- **Check output stays inline.** A `file_when: check_fails` producer's stdout is
  what *this run* found, not a standing procedure. It never moves.

Every playbook therefore opens `# Heading`, blank line, paragraph — that opening
is the abstract the filed issue renders, and `producers.yml` validates it at
parse time along with the path.

## Two phases, two locks

Phase A is **vitals** — the devops self-update, the runner heartbeat, lease
heartbeats, the registry report, and the 4-hour hard timeout — and it always
runs. Phase B is **work** — reap, producers, claim — and it is skipped entirely
when a previous tick still holds the lock.

Putting both under one lock inverts the system's own alarm: a slow Phase B would
block heartbeats on a perfectly healthy machine, tripping the offline invariant
and, worse, letting leases lapse so `expire_issue_leases` requeues work that is
still running. Locking is Ruby's `File#flock`; `flock(1)` does not exist on
macOS.
