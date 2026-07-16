## How this pipeline works

- **Repo**: `mbryzek/devops` — deploys, k8s manifests, alerting, and the `dev` CLI.
  Configuration is Apple's Pkl (`generate-json.rb` / `generate-k8s.rb` render it); manifests
  under `k8s/`; operational scripts under `scripts/` and `bin/`; Ruby libs under `lib/`.
- **Cluster**: DigitalOcean Kubernetes, driven with `doctl` + `kubectl`. Images are built and
  pushed to the DO registry (`bin/k8s-build`), then rolled out (`bin/k8s-deploy`).
- **Releases**: `dev deploy check` reports what needs a release; `dev deploy status` reads the
  live version of each deployable app (`/_internal_/version` or the live k8s image tag) — the
  same signal `dev issue reconcile` uses.
- **Secrets** live in `~/code/env` (git-crypt) and drift from the live k8s secret. NEVER unlock
  the env repo; work in place per `~/code/CLAUDE.md`.

## Decoding the issue

- The **title** is the one-line report; the **body** carries the detail — for auto-filed issues,
  the evidence (alert text, log lines, failing command output). Start there.
- **`occurrence_count` > 1 means it recurs** (the tracker dedups on `fingerprint`, bumping the
  count and adding a timeline comment). A high count means it is still firing — fix the cause,
  not the alert.
- **Read the live state before changing anything.** Confirm with `kubectl` / `doctl` / `dev
  deploy status` what is actually running; the repo and the cluster drift.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first.
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-infra-<date>`);
   clone `devops` (plus any repo the change touches). Never edit `~/code/devops` directly.
3. Group related issues into one branch/PR — one root cause, one fix.
4. Verify: this repo's Ruby tests for the files you touch (`ruby -Itest test/<file>.rb`) and
   `ruby -c` on any script you edit; render Pkl (`./generate-json.rb`, `./generate-k8s.rb`) and
   diff the output rather than asserting it is fine. Read-only checks against the cluster are
   fine; anything destructive or production-facing STOPS and asks first.
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main per the standard done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
