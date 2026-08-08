#!/usr/bin/env bash
#
# The Scala variant of templates/ci/build.sh (ISS-848) — platform, acumen, and
# anything else that runs sbt against a database.
#
# READ templates/ci/build.sh FIRST: the four load-bearing properties (landing the
# file IS the enrolment, `set -euo pipefail` is not style, the fleet posts the
# `ci` context, and `# ci-needs:` drives the preflight) are explained there and
# are unchanged here. What follows is only what sbt and a database add.
#
#   THE SESSION DATABASE IS NOT NEW MACHINERY. This does exactly what every
#   Claude session already does: `claude-db start --app <app> --port "$(claude-db
#   next-port)"`, exporting CONF_DB_DEV_URL in the SAME shell as sbt. Never
#   :5432 — that is Mike's own database, and a build that reached it would
#   corrupt his data while looking green.
#
#   CAPTURE THE START ON ITS OWN LINE AND CHECK IT. A `claude-db start | grep |
#   sed` pipeline reports only sed's status, so a start that FAILED exits 0 with
#   CONF_DB_DEV_URL unset — and unset is the shared :5432 (ISS-735). That is the
#   whole reason this is a script rather than a chain in a config file.
#
#   ONE DATABASE PER RUN, AND IT IS FRESH. The suite is not idempotent against
#   its own database: eight consecutive platform runs on ONE session database, on
#   unmodified `main`, went from 6m26s and 3 failures to 3h35m and 23 failures,
#   with 131,632 rows left in `tasks` (ISS-761, ISS-801). A runner that reuses a
#   database degrades run over run and starts parking good PRs, and the reds it
#   produces look like flaky tests rather than a dirty fixture.
#
#   CLAUDE_SESSION_ID is what buys that, and the fleet names it with the run, the
#   ATTEMPT and the SHARD — a name missing the attempt lets a retry inherit rows
#   from an attempt whose `claude-db end` never fired, and one missing the shard
#   hands every shard the same database to write over. It is set for you; do not
#   override it. The `reset` below is belt and braces on top: freshness by
#   construction is exactly the property that stops holding when somebody edits
#   the caller, and the reset is a no-op on a database just cloned from the
#   template.
#
#   THE HEAP IS THE MACHINE'S, AND IT IS ALREADY SET — do not put a number here.
#   sbt's own default is 1G and platform OOMs at it, but the right ceiling
#   differs per box, so the fleet derives it from the runner's RAM and slot count
#   and exports `SBT_OPTS` into this script's environment (Agent::Heap, ISS-753).
#   `dev ci verify` by hand sets the same value, so a build behaves identically
#   either way, and `dev agent sbt-opts --explain` shows the arithmetic.
#
#   DO NOT "fix" this with `sbt -J-Xmx...`. sbt's launcher builds
#   `java $JAVA_OPTS $SBT_OPTS ... -jar sbt-launch.jar` and folds `-J` args into
#   the JAVA_OPTS half, so the environment wins and the flag is silently ignored.
#   Measured on a runner: a `-J-Xmx12G` build ran at the 40G heap an inherited
#   SBT_OPTS asked for.
#
#   WHAT YOU DO SAY IS THE MINIMUM THIS SUITE NEEDS — `heap:<N>G` in the
#   `ci-needs` line below (ISS-1123). That is not the ceiling; it is the
#   scheduler's admission test, read before a runner claims the job. Without it
#   a suite needing 12G is claimable on the 24G/3-slot mini, which gives 4G, and
#   OOMs — a red the merge lane cannot tell from a failing test, on a pull
#   request that did nothing wrong.
#
#   MEASURE IT, CHANGE IT, DO NOT COPY IT. 12G is PLATFORM's recorded baseline
#   and a number every gigabyte of which narrows the set of machines that can
#   build this repo. For a smaller Scala suite, run it under a smaller
#   `SBT_OPTS` and declare what it actually took; `dev agent sbt-opts --explain`
#   prints what a given box would give it.
#
# ci-needs: docker, registry, database, heap:12G
set -euo pipefail

APP=platform   # CHANGE ME

echo "building ${CI_REPO:-?} @ ${CI_SHA:-?} (${CI_EVENT:-?}, clean=${CI_CLEAN_BUILD:-?})"

db_out=$(claude-db start --app "$APP" --port "$(claude-db next-port)")
export CONF_DB_DEV_URL
CONF_DB_DEV_URL=$(printf '%s\n' "$db_out" | sed -n 's/^CONF_DB_DEV_URL=//p')
[ -n "$CONF_DB_DEV_URL" ] || { echo "claude-db start produced no CONF_DB_DEV_URL" >&2; exit 1; }

# ALWAYS, including on a failure: the containers and host ports are a
# machine-wide resource, and the hourly `claude-db gc` is a backstop for what
# this misses rather than a substitute for it.
trap 'claude-db end || true' EXIT

claude-db reset --app "$APP"

# CHANGE ME — the repo's own suite. Run only the subprojects the PR affects,
# failing OPEN to the full build whenever the mapping cannot resolve a changed
# path (ISS-762).
sbt test
