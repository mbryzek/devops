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
#      `heap:<N>G` is the fifth entry and the only one that is a NUMBER, and it
#      is read one step earlier than the rest — by the SCHEDULER, before this box
#      claims the job at all (ISS-1123). The fleet is heterogeneous: the 64G
#      laptop at concurrency 1 gives a build 24G and the 24G mini at concurrency
#      3 gives it 4G, and a suite that needs 12G claimed by the mini does not
#      fail, it OOMs — which the merge lane cannot tell from a red suite, so it
#      parks the pull request and somebody investigates a scheduling mistake.
#      Declare it and the job only ever lands somewhere it fits.
#
#      DECLARE A MEASURED NUMBER, NOT A COMFORTABLE ONE. Every gigabyte here
#      narrows the set of machines that can build this repo, and a repo that
#      declares more than any runner gives is one no runner ever claims (the
#      fleet files an issue rather than letting it sit, but the PR is stuck
#      until somebody acts on it). Omit the line if the build is an npm or Elm
#      one: those need nothing beyond the JVM-less default.
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

# THE BUILD IS A VERDICT `npm run check` CANNOT GIVE, and it is why this line is
# in the template rather than left to each repo to remember (ISS-868, ISS-870).
# SvelteKit's "$lib/server imported into browser code" guard is a vite BUILD
# plugin, so svelte-check is blind to it — as it is to a bad adapter config and
# every other build-only vite failure. A repo that never builds in CI is a repo
# whose RELEASE is the first thing that ever builds it, and `release-sveltekit`
# stamps the version before the build step: the leak surfaces from a `dev deploy`
# that has already tagged and pushed. playbook-admin 0.4.42 is what that looks
# like — tag pushed, nothing deployed.
#
# Build ONE mode even where a repo has several (`build:plybk` and friends). They
# differ in committed VITE_* values, and every failure this catches is a property
# of the module graph rather than of the mode.
npm run build
