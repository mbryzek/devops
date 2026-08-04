#!/usr/bin/env bash
# Run `api lint` on a fresh clone of each spec-owning repo and open a PR where it changes files.
# dev-script: targets=local
#
# Usage: dev scripts run api-lint-pr [repo ...]
#        (no repos = every repo in DEFAULT_REPOS below)
#
# Exit codes are the producer contract (devops/agent/producers.yml):
#   0  every repo handled — clean, or a PR was opened
#   2  the script itself broke for at least one repo (clone, lint, push, gh)
# Never exits 1: there is no "findings" state here, because the repo that has
# findings gets a PR rather than an issue. The `api-lint` producer is
# `file_when: never` for exactly that reason.
#
# Requires: api (apibuilder CLI), git, gh (authenticated).

set -uo pipefail

export PATH="$HOME/code/devops/bin:/opt/homebrew/bin:$PATH"

DEFAULT_REPOS=(platform acumen dependency lib-ai)

REPOS=("$@")
[ ${#REPOS[@]} -eq 0 ] && REPOS=("${DEFAULT_REPOS[@]}")

WORKROOT="$HOME/code/ai/api-lint"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mkdir -p "$WORKROOT"

# Every repo's .api/config.pkl amends "../../devops/api/ApiConfig.pkl" — it
# expects a sibling `devops` next to the clone. Provide it via symlink so the
# relative path resolves inside our working root and never reaches ~/code/<repo>.
ln -sfn "$HOME/code/devops" "$WORKROOT/devops"

broke=0

lint_one() {
  local name workdir remote lint_out date branch pr_url
  name="$(basename "$1")"
  workdir="$WORKROOT/$name"
  remote="git@github.com:mbryzek/${name}.git"

  # Fresh FULL clone every run into our own working dir. Never --depth: a
  # shallow clone cannot be rebased or pushed from reliably (CLAUDE.md), and
  # `gh pr create` needs real history.
  rm -rf "$workdir"
  log "$name: cloning $remote"
  if ! git clone --quiet "$remote" "$workdir"; then
    log "$name: ERROR clone failed"
    return 1
  fi
  log "$name: cloned at $(git -C "$workdir" rev-parse --short HEAD)"

  log "$name: running api lint"
  if ! lint_out="$(cd "$workdir" && api lint 2>&1)"; then
    log "$name: ERROR api lint failed"
    echo "$lint_out"
    return 1
  fi

  if [ -z "$(git -C "$workdir" status --porcelain)" ]; then
    log "$name: clean — no changes produced"
    rm -rf "$workdir"
    return 0
  fi

  log "$name: lint produced changes"
  git -C "$workdir" status --short

  date="$(date '+%Y%m%d')"
  branch="api-lint-${date}"
  # A branch of this name already on the remote means an earlier run's PR is
  # still open; add a time suffix rather than force-pushing over it.
  if git -C "$workdir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    branch="${branch}-$(date '+%H%M')"
  fi

  git -C "$workdir" checkout -b "$branch" --quiet || return 1
  git -C "$workdir" commit -a --quiet -m "chore: remove unused imports (api lint)

Automated weekly api lint cleanup, run by the \`api-lint\` producer
(devops/agent/producers.yml).

$lint_out" || return 1
  git -C "$workdir" push -u origin "$branch" --quiet || return 1
  log "$name: pushed branch $branch"

  # Draft first, then ready — the same two-step every PR here goes through, so
  # Reviewable sees a complete PR rather than one that grows under it. No
  # --base: it defaults to main, and passing it is what creates stacked PRs.
  pr_url="$(cd "$workdir" && gh pr create --draft \
    --head "$branch" \
    --title "chore: api lint cleanup ($date)" \
    --body "Automated weekly \`api lint\` run removed unused imports.

\`\`\`
$lint_out
\`\`\`

Filed by the \`api-lint\` producer (devops/agent/producers.yml). Review the diff and merge if it looks good." 2>&1)" || {
    log "$name: ERROR gh pr create failed: $pr_url"
    return 1
  }
  (cd "$workdir" && gh pr ready "$pr_url" >/dev/null 2>&1) || log "$name: WARNING could not mark $pr_url ready"
  log "$name: PR created $pr_url"

  rm -rf "$workdir"
  return 0
}

for repo in "${REPOS[@]}"; do
  lint_one "$repo" || broke=1
done

[ "$broke" -eq 0 ] || exit 2
exit 0
