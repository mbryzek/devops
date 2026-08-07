#!/usr/bin/env bash
#
# The reference `ci/build.sh` (ISS-848). Copy to `ci/build.sh` in a repo, change
# the marked place, `chmod +x` it, and merge it.
#
# READ docs/ci.md BEFORE COPYING THIS. Four things about it are load-bearing and
# none of them is obvious from the shell:
#
#   1. LANDING THIS FILE IS THE ENROLMENT. A repo is verified by the fleet
#      exactly when `ci/build.sh` exists at a pull request's head sha — there is
#      no registry to keep in step with the repos that have one. That cuts both
#      ways: a broken script here parks EVERY pull request in the repo, because
#      the merge lane refuses anything whose `ci` check is not green. Confirm the
#      first build by hand before leaving the lane to depend on it:
#
#        dev ci verify --repo mbryzek/<repo> --sha <head sha> --pr <n> --no-post
#
#   2. `set -euo pipefail`, AND IT IS NOT STYLE. A pipeline reports only its LAST
#      command's status, so `claude-db start | grep | sed` with a FAILED start
#      exits 0 — leaving CONF_DB_DEV_URL unset, which is the shared :5432, which
#      is Mike's own database (ISS-735). One exit status, no exceptions.
#
#   3. THE CHECK IS NAMED `ci` AND THE FLEET POSTS IT. Nothing in this file names
#      it; `dev ci verify` does. So do not add a GitHub Actions workflow that
#      also posts `ci` — two producers of one context race on the same commit and
#      the lane reads whichever landed last. One producer per repo.
#
#   4. `# ci-needs:` BELOW IS READ BY THE PREFLIGHT. It says what this build
#      touches, so a Node unit suite is not held to a Docker daemon it never
#      starts and a Scala suite IS held to the registry credential it needs. Read
#      at the sha being built, so a suite that stops needing Docker stops being
#      held to one in the same commit. Names: docker, registry, database.
#      Omit the line entirely for a build that needs nothing but disk.
#
# ci-needs:
set -euo pipefail

# What the fleet sets for you. Every one of them is also set by hand-running
# `dev ci verify`, so this script behaves identically either way:
#
#   CI=true            CI_REPO=owner/repo   CI_SHA=<the commit being built>
#   CI_PR=<number|"">  CI_EVENT=pull_request|push
#   CI_CLEAN_BUILD=true|false   — the incremental state has ALREADY been cleaned
#                                 accordingly; this is here so a build can say so
#                                 in its own log.
#   CLAUDE_SESSION_ID  — names run + attempt + shard, and is what `claude-db`
#                        keys a database on. Never override it.
#   PATH               — this devops checkout's bin/ is prepended, so `claude-db`,
#                        `dev` and `api` are the fleet's own copies.

echo "building ${CI_REPO:-?} @ ${CI_SHA:-?} (${CI_EVENT:-?}, clean=${CI_CLEAN_BUILD:-?})"

# CHANGE ME — this repo's suite.
#
# Note there is deliberately no Playwright variant: every one of these repos
# needs a live backend for it, so a browser suite cannot produce a verdict here,
# and a check that is red for an infrastructure reason is worse than no check —
# the lane cannot tell it apart from a real failure.
npm ci
npm run check
npm run test:unit
