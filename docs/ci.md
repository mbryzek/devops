# CI: the fleet verify job

How the `ci` check the merge lane depends on is produced, and the four ways a
correctly-written build still produces a wrong answer.

ISS-754 built the lane: it merges a PR only when the `ci` check passed on the
exact commit about to be squashed, and that commit contains the current tip of
`main`. It reads one fact. This document is about making that fact worth reading.

**Nothing here is enforced by GitHub.** There is no branch protection anywhere in
this account and none is being adopted, so `gh pr merge` on a red PR succeeds.
The lane is the only merger and this is the only thing that verifies. Both are
code in this repo, with tests, because there is no second layer to catch either.

---

## What produces the check

A **verify job**: the second unit of work `Agent::Tick` schedules, and
deliberately not a Claude session.

```
checkout <repo>@<sha> (detached)  ->  ci/build.sh  ->  POST /statuses/<sha> context=ci
```

No model. A fixed command, an exit code, a deadline and a commit status. Scoping
it as "a session that runs the tests" would put an LLM in the one loop that has
to be deterministic, and would bill tokens per re-verification — of which there
are many, for the reason in the next section.

`Agent::MergeLane` needs no change to read it, and that is the property that made
this swap cheap: `check_name` already reads `name` **or** `context`, and
`check_state` already reads `state` **or** `status`+`conclusion`, because GitHub
returns CheckRuns and StatusContexts through the same `statusCheckRollup` array.
A commit status posted by the fleet lands in the arm that was already there. The
suite asserts that arm exists, so a later refactor cannot quietly drop it.

### Why there is no GitHub Actions half any more (ISS-848)

ISS-763 produced this check from GitHub Actions on self-hosted runners, and
carried a reservation file, a flock slot semaphore, a subtraction inside
`Agent::Tick#session_capacity`, and a per-repo-per-box human install that mints a
registration token on a personal account.

Every one of those existed for one reason: **Actions is a second scheduler on
hardware the tick already schedules.** Neither can see the other, so they need an
agreed split. None of it is about verifying code. Delete the second scheduler and
all of it goes — and two awkward things fall out in the other direction:

- **Every machine runs CI for free.** No install anywhere: a box runs verify jobs
  because it runs the tick. Under the reservation model this was the opposite of
  free — the laptop's `max_concurrency` is 1, so reserving one CI slot on it drove
  `session_capacity` to `max(1-1, 0) = 0` and it would have stopped claiming
  sessions entirely.
- **No human step.** `bin/ci-runner-install` was an account-level action no
  autonomous session may take, which is why ISS-773 sat in `needs_input`. Nothing
  here needs a credential the fleet does not already hold.

The independence argument for a hosted runner is weak enough not to weigh against
this, and it is worth writing down so nobody re-derives it as an objection.
`Agent::MergeLane.check_name` already accepts a `StatusContext`, so any agent with
`gh` can post `context=ci, state=success` on a sha today and the lane will merge
on it. And `pull_request` runs the workflow file *from the PR branch*, so an
Actions PR can weaken its own `ci.yml`. A runner buys a green that is hard to
produce by accident, not one that is hard to forge — and a verify job in a
separate process on a clean checkout has the same property.

---

## The actual requirement is RE-verification

This is what an agent running the suite in-session does not satisfy, and what the
design has to.

Under the lane's AHEAD invariant, **every merge invalidates every other open PR
in that repo.** `update_branch!` merges the base under each one, which pushes a
new head sha, which needs a *new* check on *that* sha — the FRESH invariant
refuses a check attached to any earlier push. With a ~50-deep standing queue that
is verification on the order of PRs x merges, each answering in minutes,
triggered by a push nobody is watching.

Actions gave that trigger for free. The fleet has to produce it, and `scan` is
where it does.

---

## The loop

### Enqueue — the lane's own walk, read from the other side

`Agent::Verify.scan` walks every open PR in `LANE_REPOS` (minus the
self-deploying ones) and looks for the state the lane calls `:no_ci_verdict`: a
head sha with no `ci` entry in its rollup. That is the enqueue signal.

Three properties, each of which is a measured failure if dropped:

- **Dedup by (repo, head sha), fleet-wide.** The runner posts `pending` carrying
  a token only it knows, then reads the context back. GitHub keeps the latest
  status per context, so exactly one racing box sees its own token and the losers
  drop the job before spending a build. It lives on GitHub rather than in a file
  on the runner precisely because the other box has to be able to see it.
- **`pending` at ENQUEUE, not at start.** It is what makes the job visible to the
  lane (`:ci_pending`) and to a human ("queued on Mac"), and what makes the next
  scan's dedup readable off GitHub rather than out of local state.
- **A cap per pass, and what it drops is LOGGED.** One merge in a 50-PR repo
  makes 49 siblings need a new check at once; without a cap the first scan after
  a merge fills the fleet with verify jobs. A silent cap reads as "everything is
  covered" when it is not.

Reading the rollup rather than the statuses endpoint is also what lets a repo that
still produces `ci` from GitHub Actions coexist: an Actions CheckRun appears there
too, so such a repo is never enqueued here. That is a transition affordance, not a
supported end state — **one producer of `ci` per repo**, or the two race on one
commit and the lane reads whichever landed last.

### Enrolment — `ci/build.sh` at the head sha

**A repo is enrolled when `ci/build.sh` exists at the pull request's head sha.**

Same shape as the rule it replaces — enrolment was the presence of a `ci` check,
deliberately, so there is no second registry to drift from the workflows that
exist — with the file changed. Still self-describing, still enrolled by a merge
and withdrawn by a deletion, and now the enrolling commit is one the lane can
read at the sha it is verifying.

The answer is cached permanently per sha, because a sha is immutable. Without
that, ten repos with no CI would re-answer the same question every scan and burn
the API budget the enrolled ones need.

Copy `templates/ci/build.sh` (or `build-scala.sh`), change the marked place,
`chmod +x`, merge.

### Result — a commit status

```
POST /repos/{owner}/{repo}/statuses/{sha}   context=ci   state=success|failure|pending
```

Always on **the sha that was actually built**, never re-pointed at the current
head. If the branch moved underneath the build, the lane's FRESH check rejects the
result, which is correct: re-pointing it would be a green measured on a tree
nobody built.

---

## Capacity: one pool, one number

Verify jobs claim through the same tick that claims agent sessions, against the
same `max_concurrency`. That is the entire simplification — there is no second
scheduler on the box, so there is nothing to reserve, nothing to subtract, and no
way for the two to oversubscribe the machine.

What the ISS-763 reservation was buying is **priority**, and that survives as
ordering rather than as arithmetic: the tick claims verify jobs **before** it
claims sessions.

- An agent session runs for **hours** and its work is deferrable — the queue keeps.
- A verify job runs for **minutes** and a pull request is already waiting on it,
  and the lane cannot distinguish a check queued behind a four-hour session from
  a check on a dead runner. It reads `:ci_pending` and waits on both.

The honest cost, stated so nobody is surprised by it: **ordering only helps when a
slot frees.** A box saturated with four-hour sessions verifies nothing until one
ends. The reservation guaranteed a floor and this does not. That is the trade
ISS-848 accepted, and the trigger for revisiting it is queue age — see below.

`dev agent pause` covers both kinds of work, because both claim through the same
tick. That is the one lever that takes a bad machine out of the pool.

### Dedicated hardware

A Mac mini is **$599 one-time against ~$168/mo** for an equivalent cloud box. It
pays for itself in months, runs the same toolchain as the rest of the fleet, and
needs no new OS to support. Buy a mini rather than renting Linux.

Spec it for the workload, not the headline price. The base $599 config has 16G,
which under the ISS-753 formula gives ~9.6G at concurrency 1 and ~4.8G at
concurrency 2 — marginal for a platform sbt run, whose recorded baseline needed
12G and OOMs at sbt's default. **24G is the sensible minimum; 32G if it is going
to run platform CI at any concurrency.**

**Trigger:** verify-job queue age — pull requests sitting on `:no_ci_verdict` or
`:ci_pending` for longer than a build takes, because every slot is held by a
session. (It was slot-wait faults under the reservation model; there are no slots
to wait for now, so the symptom moved to the queue.)

---

## Warm state — the actual reason for building on our own hardware

Hosted minutes are why hosted CI is unaffordable at this volume. **Preserved
incremental state is why this is fast, and it is the bigger effect.**

- `~/.cache/coursier`, `~/.ivy2`, `~/.sbt`, `~/.npm` — outside any checkout, so
  dependency resolution stops being a download and nothing a build does to a tree
  can take them away.
- `target/`, `node_modules/` — zinc's incremental analysis and the node tree. They
  live *inside* the checkout, so they survive only because
  `Agent::Verify.checkout` cleans with `git clean -fd` — **without** `-x`, which
  removes untracked files a previous build left and keeps the ignored ones. The
  cold path adds `-x` and takes them too.

The checkout itself is persistent, one per repo, under `~/.platform/ci-checkouts/`
— never a session's workspace, or the green measures a tree nobody is merging.
It is the one expensive thing under `~/.platform`, and losing it costs a cold
build rather than correctness.

---

## Four failures that fake a red build (or worse, a green one)

### 1. Stale incremental state → a FALSE GREEN

The cost of the section above, and **the only one of the four with no human
downstream**: a red is read by whoever opened the PR, while a wrong green is
merged by the lane without anyone looking.

The rule, in `Agent::Ci.clean_build?`, asked by `dev ci verify` rather than
decided inline:

| event | build |
|---|---|
| `pull_request` | **warm** — the fast path, and the point of the whole design |
| `push` to `main` | **cold** — the tree every PR is measured against |
| anything else | **cold** |

Warmth is an allowlist of exactly one entry, so a trigger somebody adds next year
is cold until it is deliberately made warm.

**The cold build on `main` is not optional**: without it, "the PR builds have been
silently wrong since Tuesday" has nothing that would ever discover it. It was a
`schedule:` trigger in the workflow this replaces; it is now the same rule the PR
path uses, applied to the tip of `main` — no `ci` status on the tip, or one older
than a day, means build it, cold. That covers the nightly *and* the push trigger
in one rule, because a merge moves the tip and a new tip has no status.

### 2. A reused database → a red that is not the branch

**A verify job must get a fresh database, every time.** This is a requirement on
the runner, not a nicety.

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
`tasks`**, and the specs that went red are the ones that scan or claim from a task
lane — a spec asserting "at most `maxConcurrency` rows per pass" was asserting
against a table holding six figures of other runs' rows.

A lane fed by a runner that reuses its database therefore degrades run over run
and **starts parking good PRs**, and what it produces looks like a flaky suite
rather than a dirty fixture. Nothing in the suite noticed (ISS-801).

Two mechanisms:

- **`CLAUDE_SESSION_ID` names the run, the attempt AND the shard**, and the fleet
  sets it (`Agent::Verify.session_id`). A name missing the attempt lets a retry
  inherit the rows of an attempt whose `claude-db end` never fired; a name missing
  the shard hands every shard the same database. The attempt component carries the
  starting process as well as the second, because two machines may verify one sha
  — harmless by design, and only harmless while their databases are distinct.
- **`ci/build.sh` calls `claude-db reset --app <app>`** before sbt. Freshness by
  construction is exactly the property that stops holding when somebody edits the
  caller, and the reset is a no-op on a database just cloned from the template.

Outside CI the same guarantee comes from `./run.sh test`, which resets the session
database before every suite run (`bin/reset-session-db`). Neither path can ever
touch `:5432`: that is Mike's own Postgres.app, and the port check in
`SessionDb.shared_default_url?` is what guarantees it.

### 3. DigitalOcean auth expires

A runner that silently loses registry access cannot pull the platform DB image,
and the result is a wall of red that looks like a code failure.

Note what actually expires. The fleet does **not** store a long-lived registry
token — `doctl registry login` writes into Docker's credential store and hangs on
a Desktop helper (ISS-578), so credentials are minted per process and live for the
length of it. What expires is **doctl's own DigitalOcean auth**, and
`dev ci preflight --needs registry` asks it (`doctl account get`) *before* the
build, rather than letting the failure surface minutes later as spec failures.

Fix: `doctl auth init` on the runner. The preflight prints it.

### 4. Everything else that is not the code

A full disk has already faked spec failures on this fleet once. `dev ci preflight`
covers disk headroom, the Docker daemon, doctl, and a free session-database port,
and any of them can be added to.

A repo says what its build needs in the build script itself:

```
# ci-needs: docker, registry, database
```

Read at the sha being built, so a suite that stops needing Docker stops being held
to a Docker daemon in the same commit. Unknown names are ignored rather than
rejected — a script naming a probe a newer `dev` will have should run on today's
runner, not fail closed on its own configuration.

### How an infrastructure fault is made distinguishable

Every fault above exits **75** (`EX_TEMPFAIL`) rather than 1, and `dev ci verify`
turns that into a status whose description **leads with `INFRASTRUCTURE FAULT`**
and names the job log. Under GitHub Actions this was an annotation and a
`$GITHUB_STEP_SUMMARY` block; a fleet job has neither, so the commit status — the
one surface GitHub gives — carries it, and a person reading a red PR still learns
"fix the machine" rather than "read the diff".

**The lane is deliberately not taught to read this.** It parks a red PR either
way, and that is correct: a machine that has just proved it cannot be trusted is
not a machine whose self-classification should be believed. What differs is what a
*person* does, so the distinguishing happens where a person is.

Paging is separate and already existed. `dev ci preflight` records the fault in
`Agent::Errors` under `ci_preflight`, and `Agent::Escalation` files an issue on the
third consecutive failure — the same path a dead Docker daemon or a failing
`git pull` already takes. A clean preflight clears the streak, so "in a row" means
in a row.

---

## Silence is the one outcome nothing recovers from

The lane reads `:ci_pending` for a job still running and for a job that died, and
waits forever on both. So every exit path posts a terminal status, and there are
three layers of that:

1. **The worker's own watchdog.** `dev ci verify` bounds the build at
   `BUILD_TIMEOUT_SECONDS`, kills the process group, and posts `failure` with the
   infrastructure marker.
2. **The tick's reap.** A worker that died without answering is noticed the next
   time the tick runs. It writes two markers either side of its POST — `result`
   before, `posted` after — so the reap re-posts the *true* answer when the worker
   decided but could not post, and posts a `failure` only when the worker vanished
   before it had one. Park is the safe direction; silence is not.
3. **The abandoned-pending rule.** A `pending` status older than a job could
   possibly still be running is re-enqueued by the next scan. That is what covers
   the box that rebooted, whose job records went with it.

Only `pending` is ever re-enqueued. A `failure` is an answer, and re-running a red
PR on a timer would hide a real failure behind an eventually-green flake.

---

## The check contract

**One check name per repo: `ci`.** Shard the work however is convenient, then have
one aggregate result under that name. The lane reads one `statusCheckRollup` entry
and stays ignorant of the sharding scheme.

`code-review/reviewable` stays distinct from it. The lane already treats a pending
Reviewable context as "a human is mid-review, defer", and that must never be
conflated with "tests passed".

---

## Rolling a repo in

**A repo enrolled with a broken `ci/build.sh` parks every one of its pull
requests**, because the lane refuses anything whose `ci` is not green. So the
first build per repo is confirmed by hand:

```
dev ci scan                                     # what the fleet would enqueue
dev ci verify --repo mbryzek/<repo> --sha <head sha> --pr <n> --no-post
```

`--no-post` runs the identical code path the fleet runs and posts nothing. Then
land `ci/build.sh`, watch one PR go `no_ci -> pending -> success`, and confirm
`dev agent merge-lane <repo>` has moved off `:no_ci_verdict` before letting it
merge anything.

Order: **`playbook-admin` first** (small suite, and its Reviewable review
auto-completes, so the lane's verdict is the only thing gating). **`platform`
last**, once ISS-761's measurement lands and ISS-762's affected-subproject
targeting is exercised. **`devops` never** — merging here deploys fleet-wide in 30
seconds, so a check buys a human signal and no automation, and spending fleet
capacity on a signal no machine will act on is capacity the enrolled repos need.

---

## Deliberately out of scope

- **No Playwright.** Every one of these repos needs a live backend for it, so
  `npm test` means unit suites only. A browser test that cannot run is not a merge
  gate.
- **No deploys and no library publishing.** Deploys stay manual; that is the
  entire safety argument the reversibility gate rests on.
- **`devops` is not in the lane** and never will be: merging here deploys
  fleet-wide within 30 seconds.

---

## Reference

| command | what it does |
|---|---|
| `dev ci scan [--main] [--limit N]` | what the tick would enqueue right now; posts nothing |
| `dev ci verify --repo R --sha S [--pr N] [--no-post]` | build one commit and post the `ci` status |
| `dev ci preflight [--needs ...]` | is this runner fit to produce a verdict |
| `dev ci clean-build --event E` | should this run discard incremental state |
| `dev agent pause` | take this machine out of the pool — sessions and verify jobs both |

Code: `lib/agent/verify.rb`, `lib/agent/ci.rb`, `lib/agent/tick.rb`
(`capacity`, `verify`), `lib/agent/escalation.rb`, `templates/ci/`.
Tests: `test/test_agent_ci.rb`, `test/test_agent_verify.rb`.
