# CI on self-hosted runners

How the runners the merge lane depends on are provisioned, and the four ways a
correctly-written workflow still produces a wrong answer.

ISS-754 built the lane: it merges a PR only when the `ci` check passed on the
exact commit about to be squashed, and that commit contains the current tip of
`main`. It reads one fact. This document is about making that fact worth reading.

**Nothing here is enforced by GitHub.** There is no branch protection anywhere in
this account and none is being adopted, so `gh pr merge` on a red PR succeeds.
The lane is the only merger and `dev ci` is the only admission control. Both are
code in this repo, with tests, because there is no second layer to catch either.

---

## Quick start

On a machine that should run CI:

```
dev ci install --slots 1              # reserve capacity FIRST
bin/ci-runner-install mbryzek/<repo>  # then register a runner (a human step)
dev ci status
```

Then, in the repo, copy `templates/ci/ci.yml` (or `ci-scala.yml`) to
`.github/workflows/ci.yml`, change the two marked places, and merge it.

**Order matters.** Enrolment in the lane is the presence of the `ci` check, so
landing the workflow before a runner is listening gives every PR in that repo a
check that queues for 24 hours and then fails. Runner first, always.

---

## Capacity

Both existing fleet machines were already fully committed to agent sessions:

| machine | hardware | agent concurrency |
|---|---|---|
| `Michaels-MacBook-Pro.local` | M4 Max, 16 cores, 64G | 1 |
| `Mac` | M4, 10 cores, 24G | 3 |

CI capacity has to come from somewhere, and taking it from the fleet is the
correct trade: the fleet already produces more PRs than can be merged — a ~50-deep
standing queue is the evidence — so converting session slots into verification
slots moves capacity from the over-supplied side to the bottleneck.

- **`Mac` (24G):** agent concurrency 3 → 2, CI gets 1–2 slots. Same total load,
  better mix. (Dropping to 2 is what ISS-753 wants anyway, on memory grounds.)
- **`Michaels-MacBook-Pro.local`:** leave it alone. It is Mike's laptop, and CI
  jobs stealing cycles while he works is a bad trade for one extra slot.

### One pool, one number

`max_concurrency` is derived server-side from the hardware a runner reports — a
fact about the machine. **How that capacity is split is not**: it is an
operator's decision about one box, so it lives in `~/.platform/ci.json`, written
by `dev ci install` and read by both `dev ci run` and the tick.

The tick subtracts the reservation from `max_concurrency` before it claims
(`Agent::Tick#session_capacity`). Two schedulers each sizing themselves to the
same machine is how a box ends up swapping at 100% CPU making progress on
neither, and this is the one number that stops it.

### Reserved, not borrowed

The reservation comes out of the tick's capacity **whether or not a CI job is
running**. When no PR is open, those cores sit idle rather than running one more
session. That is deliberate:

- An agent session runs for **hours** and its work is deferrable — the queue
  keeps.
- A CI job runs for **minutes** and something is already waiting on it.

If CI had to borrow a slot back from a running session, a PR would wait hours for
a check — and the lane cannot distinguish a check queued behind a four-hour
session from a check on a dead runner. It reads `:ci_pending` and waits, forever,
on both. An idle core is a cheaper mistake than a merge queue that stops.

### Why the slot semaphore exists at all

`mbryzek` is a personal account, not an organization. GitHub supports self-hosted
runners at repository, organization and enterprise level — **so repository level
is the only option here**. Eight repos means eight listener processes on a box,
each of which will accept a job the instant one is queued, and nothing at the
GitHub layer limits their sum.

`dev ci run` is that limit. It holds one of the reserved slots for the length of
the build, using `flock` on N lock files — so liveness is the kernel's problem, a
killed job releases its slot when the fd closes, and there is no lease, expiry or
reaper to go wrong. **A workflow step that shells the build directly bypasses it
and oversubscribes the machine.**

A job that waits out `--wait` without getting a slot exits 75 as an
infrastructure fault, not as a test failure. That is also the signal that this
box is short of capacity, which makes the buy-a-mini trigger below measurable
rather than a feeling.

### Dedicated hardware

A Mac mini is **$599 one-time against ~$168/mo** for an equivalent cloud box. It
pays for itself in months, runs the same toolchain as the rest of the fleet, and
needs no new OS to support. Buy a mini rather than renting Linux.

Spec it for the workload, not the headline price. The base $599 config has 16G,
which under the ISS-753 formula gives ~9.6G at concurrency 1 and ~4.8G at
concurrency 2 — marginal for a platform sbt run, whose recorded baseline needed
12G and OOMs at sbt's default. **24G is the sensible minimum; 32G if it is going
to run platform CI at any concurrency.**

**Trigger:** CI queue time on `Mac` exceeding what a slot rebalance can fix —
visible as repeated slot-wait faults. Likely once platform enters the lane.

---

## Warm state — the actual reason for self-hosting

Free minutes are why hosted CI is unaffordable. **Preserved incremental state is
why self-hosted is fast, and it is the bigger effect.**

- `~/.cache/coursier`, `~/.ivy2`, `~/.sbt`, `~/.npm` — created by `dev ci
  install`, outside any workspace, so dependency resolution stops being a
  download. They survive whatever `actions/checkout` does to the tree.
- `target/` — zinc's incremental analysis. It lives *inside* the checkout, so it
  survives only with `actions/checkout`'s `clean: false`. The recorded baseline
  is ~8 minutes for a **cold** `Test/compile`; incrementally it is a fraction of
  that.

---

## Four failures that fake a red build (or worse, a green one)

### 1. Stale incremental state → a FALSE GREEN

The cost of the section above, and **the only one of the four with no human
downstream**: a red is read by whoever opened the PR, while a wrong green is
merged by the lane without anyone looking.

The rule, in `Agent::Ci.clean_build?` and asked for by every workflow through
`dev ci clean-build`:

| event | build |
|---|---|
| `pull_request` | **warm** — the fast path, and the point of self-hosting |
| `push` to `main` | **cold** — the tree every PR is measured against |
| `schedule` (nightly) | **cold** — what notices the warm path has been lying |
| anything else | **cold** |

Warmth is an allowlist of exactly one entry, so a trigger somebody adds next year
is cold until it is deliberately made warm. The nightly is not optional: without
it, "the PR builds have been silently wrong since Tuesday" has nothing that would
ever discover it.

### 2. A reused database → a red that is not the branch

**A CI job must get a fresh database, every time.** This is a requirement on the
runner, not a nicety.

The suite is not idempotent against its own database. Eight consecutive platform
runs on **one** session database, on unmodified `main` (`25b091124`), measured
under ISS-761:

| run | wall | failed |
|---|---|---|
| 2 | 6m26s | 3 |
| 5 | 8m47s | 9 |
| 7 | 3h45m | 39 |
| 8 | 3h35m | 23 |

Identical code every run. After eight runs the database held **131,632 rows in
`tasks`**, and the specs that went red are the ones that scan or claim from a
task lane — a spec asserting "at most `maxConcurrency` rows per pass" was
asserting against a table holding six figures of other runs' rows.

A lane fed by a runner that reuses its database therefore degrades run over run
and **starts parking good PRs**, and what it produces looks like a flaky suite
rather than a dirty fixture. Nothing in the suite noticed (ISS-801).

Two mechanisms, and both are in `templates/ci/ci-scala.yml`:

- **`CLAUDE_SESSION_ID` names the run, the attempt AND the shard.** `claude-db`
  keys a database on it, so a name missing the attempt lets a re-run inherit the
  rows of an attempt whose `claude-db end` never fired, and a name missing the
  shard hands every matrix shard the same database to write over. It lives on the
  **job**, not on the workflow — `matrix` is out of scope in a workflow-level
  `env`, where it would expand to the empty string and silently re-share.
- **`ci/build.sh` calls `claude-db reset --app <app>`** before sbt. Freshness by
  construction is exactly the property that stops holding when somebody edits an
  `env` block, and the reset is a no-op on a database just cloned from the
  template.

Outside CI the same guarantee comes from `./run.sh test`, which resets the
session database before every suite run (`bin/reset-session-db`) and reports what
it did in the test summary. `--no-reset-db` opts out. Neither path can ever touch
`:5432`: that is Mike's own Postgres.app, it is not a session database, and the
port check in `SessionDb.shared_default_url?` is what guarantees it.

### 3. DigitalOcean auth expires

A runner that silently loses registry access cannot pull the platform DB image,
and the result is a wall of red that looks like a code failure.

Note what actually expires. The fleet does **not** store a long-lived registry
token — `doctl registry login` writes into Docker's credential store and hangs on
a Desktop helper (ISS-578), so credentials are minted per process and live for
the length of it. What expires is **doctl's own DigitalOcean auth**, and
`dev ci preflight --needs registry` asks it (`doctl account get`) *before* the
build, rather than letting the failure surface minutes later as spec failures.

Fix: `doctl auth init` on the runner. The preflight prints it.

### 4. Everything else that is not the code

A full disk has already faked spec failures on this fleet once. `dev ci
preflight` covers disk headroom, the Docker daemon, doctl, and a free
session-database port, and any of them can be added to.

### How an infrastructure fault is made distinguishable

Every fault above exits **75** (`EX_TEMPFAIL`) rather than 1, prints a
`::error title=CI INFRASTRUCTURE FAULT::` annotation, and writes a
`$GITHUB_STEP_SUMMARY` block saying in as many words that this is the runner and
not the branch. The `ci` gate job repeats the pointer when it goes red.

**The lane is deliberately not taught to read this.** It parks a red PR either
way, and that is correct: a machine that has just proved it cannot be trusted is
not a machine whose self-classification should be believed. What differs is what
a *person* does — fix the machine, versus read the diff — so the distinguishing
happens where a person is.

Paging is separate and already existed. `dev ci preflight` records the fault in
`Agent::Errors` under `ci_preflight`, and `Agent::Escalation` files an issue on
the third consecutive failure — the same path a dead Docker daemon or a failing
`git pull` already takes. A clean preflight clears the streak, so "in a row"
means in a row.

---

## The check contract

**One check name per repo: `ci`.** Shard the work however is convenient, then
have a single `ci` gate job that depends on all shards and reports the aggregate.
The lane reads one `statusCheckRollup` entry and stays ignorant of the sharding
scheme, so shards can be added and removed without ever touching the lane.

`code-review/reviewable` stays distinct from it. The lane already treats a
pending Reviewable context as "a human is mid-review, defer", and that must never
be conflated with "tests passed".

---

## Deliberately out of scope

- **No Playwright.** Every one of these repos needs a live backend for it, so
  `npm test` means unit suites only. A browser test that cannot run is not a
  merge gate.
- **No deploys and no library publishing.** Deploys stay manual; that is the
  entire safety argument the reversibility gate rests on.
- **`pull_request`, never `pull_request_target`**, and no secret in the PR job
  beyond what the runner environment already holds. Every PR here is authored by
  our own fleet rather than an outside contributor, which is why self-hosted
  runners are acceptable at all. Do not widen that.
- **`devops` is not in the lane** and never will be: merging here deploys
  fleet-wide within 30 seconds. A `ci` check on this repo would still be useful
  to a human, but it buys no automation.

---

## Reference

| command | what it does |
|---|---|
| `dev ci status` | this box's split: reserved, busy, what is left for sessions |
| `dev ci install --slots N` | reserve N slots and create the warm cache dirs |
| `dev ci preflight [--needs ...]` | is this runner fit to produce a verdict |
| `dev ci run -- <cmd>` | run a build holding one slot |
| `dev ci clean-build --event E` | should this run discard incremental state |
| `bin/ci-runner-install <owner/repo>` | register a runner (human step — needs a token) |

Code: `lib/agent/ci.rb`, `lib/agent/escalation.rb`, `bin/ci-runner-install`,
`templates/ci/`. Tests: `test/test_agent_ci.rb`.
