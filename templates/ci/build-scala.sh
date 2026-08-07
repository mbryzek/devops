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
#   THE HEAP IS THE MACHINE'S. platform needs ~12G and OOMs at sbt's default, and
#   the right number differs per box (ISS-753). Size it against the smallest
#   machine in the fleet that will run this, not the largest.
#
# ci-needs: docker, registry, database
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
sbt -J-Xmx12G test
