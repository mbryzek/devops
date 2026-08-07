# `dev agent` — the autonomous dispatcher

Mac minis that pick up work as it arrives and drive each unit to a ready PR, with
nobody dispatching by hand. Design: `~/code/claude/plans/2026-08-03-agent-dispatcher-design.md`.

**`dev issues` is the only queue.** There is no job table and no second place to
look. Everything here exists to drain the open issue queue.

## What is in this directory

| File | What it is |
|---|---|
| `instructions.md` | Part 1 of every session's prompt. Outcome protocol (including the close-out contract: before it closes out, a session files what it WORKED AROUND and hands over what only a HUMAN can run), the relaxed review gates, and the safety rules that are *not* relaxed. Reviewed like code. It is also why a playbook never restates any of that — reaching every session, including the next playbook's, is what this file is for. |
| `githooks/pre-push` | Enforces "an autonomous session may only write to `plans/` in `~/code/claude`". Injected into every session via `core.hooksPath`. |

## The commands

```
dev agent tick [--dry-run]        one shot; launchd runs it every 30s
dev agent status                  this machine: identity, live jobs, last tick
dev agent logs <issue> [--follow] tail one session's claude.log
dev agent pause | resume          kill switch — drains, claims nothing new
dev agent runners                 the fleet: capabilities, concurrency, last seen
dev agent producers               the platform's registry: schedule, last run, next due
dev agent runs [<key>] [--issue N] producer run history and lease attempts
dev agent playbooks               the catalogue: every playbook's current version
dev agent playbook <key>          one playbook — read it, --versions, or --write FILE
dev agent refresh <issue>         re-open a fixed issue for rebase / review feedback
dev agent release <issue>         force-release a stuck lease
dev agent gc                      purge logs and workspaces per the retention table
dev agent maintenance             this machine's housekeeping: gc + aidirs/docker prune
dev agent doctor                  does this box have the binaries its jobs shell out to?
```

`dev agent tick --dry-run` prints every decision a real tick would make and
executes none of them. It doubles as the provisioning smoke test on a new
machine: if it registers a runner, reports its capacity and says what it would
claim, the box is wired up. There is **no producer phase** in that output, and
there has not been one since ISS-526.

## Provisioning a machine

Install the toolchain, then:

1. `gh auth login`
2. `dev auth ai provision` (or `dev auth ai set <token>`)
3. **`dev agent doctor` — it must exit 0**
4. `cp launchd/com.bryzek.dev-agent.plist ~/Library/LaunchAgents/`
5. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bryzek.dev-agent.plist`

The first tick self-registers the machine on its `IOPlatformUUID` and the server
derives `max_concurrency` from the reported RAM. Nothing else is configured by
hand.

**CI needs no provisioning at all** (ISS-848). A box runs verify jobs because it
runs the tick: they are claimed by the same tick, against the same
`max_concurrency`, ahead of agent sessions. There is nothing to install, nothing
to reserve and no human step — the reservation, the slot semaphore and the
per-repo runner install that used to be here all existed to split one machine
between two schedulers, and there is only one now. See `docs/ci.md`.

**Host prerequisites.** The toolchain half is `Agent::Toolchain::TOOLS` in
`lib/agent/toolchain.rb`: every external binary the dispatcher, its producers and
its claimed sessions shell out to, with what each one blocks and the command that
installs it. `dev agent doctor` compares this machine to that list and exits 1 if
anything required is absent; the tick re-checks once a day and files an issue
naming the machine and the producers it cannot run.

Step 3 is a gate rather than a suggestion because of ISS-531: `depsguard` was in
the prerequisites, was never installed on the runner, and the weekly
supply-chain scan therefore never ran once in the producer's whole history. It
left no error, because a check that cannot run exits 2, and the producer contract
records exit >1 as `check_failed` — deliberately indistinguishable in the queue
from a clean week.

The doctor resolves against **the PATH `/bin/zsh -lc` gives the tick, not your
shell's**. That is the same bug in its other form: `-lc` is a login,
*non-interactive* shell, so it never sources `.zshrc`, so nvm never loads, so
nvm's `node` is on PATH in your terminal and on no PATH the agent has ever had.
Install anything the agent shells out to with homebrew.

The rest — auto-login, FileVault (stays on, deliberately), sleep disabled, Docker
Desktop at login — is in the XML comment at the top of the plist. Those are the
ones no command can check for itself.

## Where everything is written

One root, `~/Library/Logs/dev-agent/`. Nothing writes anywhere else.

```
tick/YYYY-MM-DD.log        one line per decision: phase, claims, reaps, timings
issues/ISS-<n>/
  prompt.md                exactly what was fed to the session on stdin
  claude.log               the session's full stdout
  exit_code                the wrapper's record of how it exited
  meta.json                issue, pid, slug, branch, timeout_at, outcome
```

Local state, all under `~/.platform/` and all of it a **cache**: `agent.identity`
(runner id + token), `agent-jobs/<issue>.json` (is this pid alive, whether the
tick killed it, and — written before the reap acts on it — what the reap
decided),
`agent-heartbeat`, `agent-notified.json`. Delete all of it and the cost is one
re-registration plus some orphaned processes whose leases expire within ten
minutes.

`agent-maintenance` joins that list: when this machine last ran its own
housekeeping, and how it went.

Retention (`dev agent gc`): tick logs 30 days; a terminal issue's
directory 14 days; a failed or gave-up one 30 days — the post-mortem window;
workspaces deleted on success and after 7 days otherwise.

`dev agent gc` is the **sole** collector of workspaces, and `dev aidirs prune`
skips every executor-minted directory for that reason (ISS-631) — `i<issue>`,
`i<epic>_c<nn>`, and the `i<issue>_<rand>` form minted before ISS-767. Two
collectors sharing `~/code/ai` disagreed in both directions: prune has no notion
of a running job, so it deleted a live session's workspace during the window
between the mkdir and the first clone; and its 3-day cutoff was quietly deleting
failed jobs' workspaces four days before the post-mortem window above says they
go. The split is by NAME, which is true from the mkdir onward — a live-pid check
would still miss that first window, because the job's pid file is written only
after its repos are prepared.

## Housekeeping is runner-local, not a producer

`agent gc`, `aidirs prune` and `docker prune` run once an hour inside the tick, on
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

Two triggers: the hourly **cadence** (ISS-555 — it was daily, which left up to a
day between a machine starting to fill and noticing), and **disk pressure** —
under 50GB free the next pass uses shorter windows (feature dirs and images to 1
day), subject to an hour's cooldown so a machine that is genuinely full does not
prune on a loop. Cooldown and cadence are both an hour now, so pressure buys the
short windows rather than an earlier run. Nothing here talks to the platform: if the platform is unreachable for a
week every machine still prunes, because the moment you most need headroom is the
moment things are already broken.

What the platform does own is NOTICING that a machine stopped. Failures ride the
existing error channel (`Agent::Errors`, sources `agent_gc` / `aidirs_prune` /
`docker_prune`, escalating at 3 in a row), and the runner heartbeat carries
`last_maintenance_at` plus this machine's headroom — because an error log can
only report a run that broke, never one that never happened. Both ride the
HEARTBEAT rather than the runner's since-deleted registry report: they describe
the machine, and that report went away with the server-side-scheduling cutover
(ISS-526) — which is exactly why they were moved off it first. The
`agent_runner_maintenance_stale` invariant is what files a single issue naming
any live, unpaused runner that has gone quiet or is out of headroom; the same
numbers reach `/admin/agents` per machine as `is_maintenance_stale` /
`is_disk_low`, computed server-side off the invariant's own constants so the
board and the check cannot disagree.

## One push reaches the fleet

Phase A runs `git pull --ff-only origin main` in this checkout before it does
anything else, so a change to the standing prompt or the tick itself is a devops
PR and nothing more — no logging into each machine. `--ff-only` because a
diverged checkout must stop rather than merge, and a failed pull is reported,
never fatal: the machine keeps running the code it has. A pull that changes tick
code takes effect on the NEXT tick, which is safe precisely because the tick is
one shot.

**A stale checkout no longer changes what work happens.** It used to: the
schedule and the playbooks lived in this directory, so a machine on an old sha
ran an old schedule and handed sessions an old runbook — and the only way to see
that was to compare what every runner REPORTED reading (`PUT /agent/registry/:runner_id`)
and notice one was the odd one out. ISS-526 deleted that whole surface, because
the thing it watched no longer exists: there is one schedule, it is a set of rows
in the platform, and the playbooks are resolved from the platform at claim time.
A machine behind on devops now runs old *tick code*, which is a much smaller and
much louder problem:

| Why the checkout is stale | What reports it |
|---|---|
| Pull fails repeatedly (network, credentials, diverged) | `Agent::Errors` counts consecutive failures; the third notifies and files a bug issue (ISS-511) |
| Working tree dirty, or on a branch other than `main` | Nothing — a benign skip, deliberately left alone, because it means a human is working in that checkout |
| Machine is dark | `agent_runner_heartbeat_stale` |

**Which is why nothing autonomous merges a devops PR** (ISS-660). Everywhere
else, merging and shipping are two acts with a human between them, and that gap
is the entire safety argument for the `pr_auto_merge` loop: a merged PR sits on
`main` until Mike deploys, so a revert PR opened in the meantime fully undoes it.
Here the gap does not exist — the merge IS the deploy, it reaches every runner
within one 30-second tick, and `gh pr revert` opens a revert PR rather than
merging one. Worse, the change that would need reverting is the code that runs
the fleet: break `dev agent tick` and you have also taken out the machines that
would deliver the fix. So a devops PR is `irreversible` by the merge loop's own
test ("does reverting this before it ships fully undo it"), whatever it touches,
and `agent/instructions.md` §3 forbids merging one at all — a rule in the
standing prompt rather than in a playbook, because it must hold for every
session, not just for the one whose runbook currently remembers it.

## One copy of the plan, and it is the current one

A producer's issue carries a **pointer** to its playbook, never a copy of it
(ISS-505). The filed body carries the playbook's abstract and a ``Playbook: `key` ``
line; the claiming runner resolves that key against `GET /agent/playbooks/:key`
and hands the text to the session.

Copying froze it. An issue filed on Friday and claimed on Tuesday ran Friday's
procedure, and every improvement made in between applied to nothing already in
the queue — which defeats the reason these are nightly producers at all.
Resolution happens at CLAIM time, not file time.

The playbooks themselves are **append-only rows in the platform** (ISS-523), not
files in this repo — `agent/bodies/` was deleted by ISS-526. Editing one INSERTS
a new version and `created_at` is the version; nothing is ever updated in place
and nothing is ever deleted. Manage them at `/admin/agents/playbooks`, or from
the terminal:

```
dev agent playbooks                        # the catalogue
dev agent playbook weekly-review > wr.md   # body to stdout, `key @ version` to stderr
$EDITOR wr.md
dev agent playbook weekly-review --write wr.md   # diff, then confirm
dev agent playbook weekly-review --versions      # the history
dev agent playbook weekly-review --version 2026-07-30   # one past body
dev agent playbooks --lint                 # check the whole store, exit 1 on a finding
dev agent playbook weekly-review --lint    # ...or just this one, before a --write
```

`--lint` is the only mode that is a CHECK rather than a read, so it is the only
one that fails the shell. It reports the three defects an instruction can carry
that no session can execute — a path hardcoded under one user's home, a write
into `~/code/claude` outside `plans/`, and a write to an undated top-level
`plans/` file (ISS-633, ISS-644). All three fail at the END of a run, after the
work is done, with nothing saying so, which is why the catalogue also flags them
inline: a lint you have to know to ask for is one nobody asks for.

The write is gated, and each gate guards a mistake the append-only design makes
permanent rather than merely wrong (ISS-665). An unchanged body writes nothing —
a log whose entries may be duplicates cannot answer "what changed and when",
which is the only question it exists to answer. A key with no history needs
`--create`, because a typo'd key does not fail: it starts a lineage no producer
points at, silently, while the edit that was meant to land never does. And the
append itself needs a yes — a human at a terminal is prompted, and **a Claude
session, a pipe or cron is refused unless `--yes` is passed**, so no autonomous
run rewrites the instructions the next autonomous run obeys as a side effect of
doing something else.

Before this existed there was one READ (`Agent::Api.playbook`, used at claim
time) and no write at all, so a session told to fix a playbook hand-rolled the
POST — a production table edited with no key validation, no diff and no
confirmation.

Three things fall out of that and none of them is optional:

- **The runner records what it read** — `Playbook: <key> @ <created_at>`, as the
  issue's first comment. Copy-on-write is what makes that worth recording: the
  version it names is still there, and still readable, after any number of later
  edits. A git sha only gave us that while the file was still in git.
- **A pointer that does not resolve is a hard stop** — no session, and the issue
  goes to `needs_input`. Never a fallback: ISS-360 is a week of a producer doing
  generic triage because its playbook was missing and nothing said so. An
  unreachable platform lands here too, for the same reason: better no session
  than a session doing a different job.
- **Check output stays inline.** A `check_fails` producer's evidence is what
  *this run* found, not a standing procedure. It never moves.

**A check that needs a machine belongs in the playbook, not in the registry**
(ISS-525). A registry `check` is a key out of a closed set the platform runs in
process — there is no shell and no checkout on that side — so a check that clones
repos, installs packages or reads a developer box's own config cannot be one.
Those producers file unconditionally and their playbook runs the check as its
FIRST step, closing the issue `dismissed` when it comes back clean.
`codegen-sync`, `depsguard` and `browserslist-update` are the three, and they
were the last reason a producer needed a runner at all.

## Two phases, two locks

Phase A is **vitals** — the devops self-update, the runner heartbeat, lease
heartbeats, and the 4-hour hard timeout — and it always runs. Phase B is
**work** — maintenance, the toolchain check, reap, claim — and it is skipped
entirely when a previous tick still holds the lock.

Putting both under one lock inverts the system's own alarm: a slow Phase B would
block heartbeats on a perfectly healthy machine, tripping the offline invariant
and, worse, letting leases lapse so `expire_issue_leases` requeues work that is
still running. Locking is Ruby's `File#flock`; `flock(1)` does not exist on
macOS.

## Every subprocess has a deadline

A lock that is skipped when held is the right design for work that can be slow,
and it is a trap for work that can HANG. Phase B holds the work lock across
maintenance, the toolchain check, reap and claim; a subprocess in there that
never returns holds that lock forever, so every later tick finds it held and
skips — the machine keeps heartbeating, keeps looking healthy, and never claims
another issue. Nothing is logged, because a hang is not an exception. The
candidates are ordinary: `docker --version` against a wedged daemon, `sbt
--script-version` on a launcher that wants the network, `docker prune` under
exactly the disk pressure it exists to relieve, a stalled `gh pr list`.

So `Agent::Shell.capture` (`lib/agent/shell.rb`) is the ONLY thing under
`lib/agent` that may call `Open3`, every call names its own timeout in seconds,
and `test_dev_agent_shell.rb` enforces both by scanning the directory (ISS-740).
A timeout that has to be remembered is one that gets forgotten once and wedges a
runner for a week — which is the literal history here: `Agent::Checkout` bounded
its `git pull` in ISS-511 and wrote down why, and every module added afterwards
shelled out unbounded anyway.

Three properties are load-bearing rather than incidental: output is drained on
its own thread (a command that outruns the ~64KB pipe buffer blocks on write, so
a join-then-read helper would kill every chatty command — `docker prune` listing
what it removed is precisely one), the process GROUP is what gets killed (`dev
docker prune` is Ruby shelling out to `docker`; killing only the Ruby leaves the
wedged docker), and the signal is `KILL` (a process wedged on an
uninterruptible read is the one that ignores `TERM`).

## Notifications are a nudge, and the platform is the record

`Agent::Notify` shells out to `openclaw`, which **is not installed on the
runners**. Every push the dispatcher has ever attempted from a mini has been a
no-op, and nothing said so, because a `false` return went into a caller that
discarded it (ISS-535 — the same shape as ISS-531's `check_failed`, where a
check that *could not run* was indistinguishable from one with nothing to say).

That is survivable, and it is survivable for a reason worth stating rather than
rediscovering: **every kind of push carries the same fact somewhere durable on
the platform.** `Agent::Notify::BACKSTOPS` is that table — kind → what holds the
fact when the push does not arrive — and `test_dev_agent_notify.rb` asserts it
matches the kinds the tick actually pushes, so a new notification cannot be added
without naming its backstop. A missing `openclaw` therefore costs attention
sooner, not information.

Two consequences the code now enforces:

- **The runner-offline alert does not come from a runner.** It cannot: an
  offline machine cannot report itself, and a one-runner fleet has no peer to
  report it either, so the old fleet-scan in `Agent::Tick#self_runner` reported
  nothing precisely when it mattered most. The platform owns it —
  `CheckAgentRunnerHealthProcessor`, queued every 15 minutes by `PeriodicActor`,
  alerts on the machine that *crosses* into staleness and emails Mike, off the
  same `AgentInvariants.StaleAfterHours` the runner used to read back as
  `is_stale`. Do not re-add a local copy; extend the processor.
- **An attempt that failed does not consume its window.** `Notify.once` used to
  mark `(kind, subject)` notified *before* the push, so one refusal from
  `openclaw` silently ate the notification for six hours — the single failure
  mode a retry could fix was the one guaranteed never to be retried. A `FAILED`
  push now leaves the window open. `UNAVAILABLE` still closes it: a machine with
  no channel will not grow one before the next tick, and retrying costs a process
  every 30 seconds to accomplish nothing.

`dev agent status` prints whether this box has a channel at all, and undelivered
pushes get a tick-log line naming the backstop that carried the fact instead.
Both halves are needed: "undelivered" alone reads as lost work, and the backstop
alone reads as a healthy channel.

`openclaw` is not in `Agent::Toolchain::TOOLS` and `dev agent doctor` does not
check for it — deliberately, not a shrug. It follows from the backstop table
above: every push already survives its absence, so doctor tracking it would
just be a second, noisier way of learning what `dev agent status` and the
tick log already say. The day a push is added with no durable record behind
it, the answer changes and the test is what will say so.

## Retiring an openclaw cron is a TWO-PARTY job, permanently

Migrating a scheduled job onto the agent has a last step the agent cannot take:
deleting the old cron from the openclaw gateway. Two independent walls, and
neither is a gap to close.

- `openclaw` is not installed on the runners at all, the same absence ISS-535
  documents for `Agent::Notify`.
- The agent identity lacks `operator.admin`, so even on a box that has the binary,
  `openclaw cron rm` comes back `missing scope: operator.admin`.

**Granting that scope is the wrong fix, not the pending one.** `operator.admin` is
admin over *every* cron on the gateway, and ISS-394 deliberately left a set of
them there: the morning-briefing fragments, `email-drafter`, and the personal and
financial checkers. An agent credential that can delete `codegen-sync-weekly` can
delete those too, and no amount of good intent narrows it. The gateway is
third-party software this repo does not build, so a scoped cron-delete is not
ours to add either.

So the deletion is a human step, and the only question worth engineering is how it
reaches the human. Not a PR description: ISS-396 put two `openclaw cron rm`
commands in a close-out comment on 2026-08-04 and both crons were still firing a
day later. Not `dev issues workaround` either — that files at `open`, `dev issues
claim` offers `open`, and the agent that claimed the finding could no more run the
commands than the two sessions before it (ISS-563).

`dev issues handoff` is the mechanism: it files the commands at `needs_input`,
which `dev issues claim` never offers and the daily nudge lists every morning
until a human clears it. Every future cron retirement ends with that call rather
than with a paragraph. Nothing in this repo can assert the other half — the
gateway's cron store is not visible from here, so "the replacement exists" is
checkable and "the old cron is gone" is not. The handoff issue is what carries
it, and the issue staying open is the only signal that it has not happened.
