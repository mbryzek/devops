# The GitHub merge webhook

`POST /webhooks/github` on the platform is what moves an issue out of `claimed`
the moment its `ISS-<number>: ...` pull request merges. The endpoint, the HMAC
verification, the forward-only guard rails and the processor all shipped in July
2026 (platform #1870, ISS-132).

**The other half — telling GitHub to call it — was never done, and for a month
the documented primary mover of `claimed -> fixed` moved zero issues** (ISS-537).
Nothing said so, because a webhook nobody configured fails by delivering
nothing, which reads exactly like a quiet queue.

## Why it is per-repository

The design assumed an org-level webhook on `mbryzek`, the way Reviewable is
wired. **`mbryzek` is a GitHub USER account, not an organization**, and a user
account has no org-level webhook to configure. So it is one hook per repository
— which is a chore, which is why it is a command:

    dev issues webhook status        # what GitHub is actually configured to do
    dev issues webhook sync --apply  # create the missing ones, repair the drifted

Both default to every non-archived, non-fork repository under `mbryzek` (52 as
of 2026-08-05). That breadth is deliberate: a repo left off the list is a repo
whose merges silently move no issue, and that omission *is* the bug. Narrow with
`--repo NAME` (repeatable) when you mean to.

`status` is read-only, needs nothing but `gh`, and **exits non-zero when
anything is missing or drifted**, so it can be a check and not just a report.
`sync` is idempotent — re-running it is the answer to "did the repo I created
last week get a hook".

## Rolling it out

Steps 1 and 2 need credentials no agent session has, by design: the secret lives
in the git-crypt'd `env` repo, and agent sessions are forbidden from unlocking
it. `sync` reads that value and never writes to it.

**1. Set the shared secret.** In `env/apps/platform/env/production.env`, with
git-crypt unlocked:

```
GITHUB_WEBHOOK_SECRET=<32 bytes of hex>
```

One value, both ends: GitHub signs each delivery with it and
`GithubWebhookParsers.verifySignature` verifies against it. Unset, the platform
rejects every delivery it receives — deliberately, since the endpoint is public
and unauthenticated by necessity, so the signature is the whole authorization
story. `dev issues webhook sync` refuses to run without it and prints a freshly
generated candidate value.

While you are in that file, ISS-534's hourly `MergedPullRequestSweeper` — the
pull half of the same mechanism, and the backstop for every merge the webhook
never sees — needs a read-only GitHub token in the same place:

```
GITHUB_API_TOKEN=<a read-only PAT>
```

It no-ops with a warning until that is set.

**2. Ship it to the running app.**

    dev config rollout --app platform     # k8s-secrets + rollout restart
    dev config check --app platform       # confirm the cluster matches the env file

**3. Add the hooks.**

    dev issues webhook sync               # dry run: what it would create
    dev issues webhook sync --apply

**4. Verify against a real merge.** Merge any PR titled `ISS-<n>: ...` and
confirm the issue advances. Without waiting for one, `dev issues webhook status`
reports the last delivery GitHub recorded per hook, so a signature mismatch
shows up as `last delivery failed: 401` rather than as silence.

## What the hook looks like

`pull_request` and nothing else. The processor acts on merged pull requests
only, so every additional event is a delivery the platform persists, queues a
task for, and discards. (Reviewable's hook on the same repos subscribes to `*`.
That is its design, not a precedent for this one.)

`sync` writes `content_type: json`, `insecure_ssl: 0`, active, with the secret.
`status` flags every one of those going wrong, plus a hook that exists but
delivers somewhere else.

## How this fails next time

The failure mode is not "the hook breaks loudly". It is:

- **a new repository** — created after the last sync, no hook, merges move
  nothing. Re-run `sync`; it only touches what is wrong.
- **a rotated secret** — the platform is redeployed with a new value and every
  hook is now signing with the old one. GitHub reports `401` on the last
  delivery, which `status` surfaces. Re-run `sync --apply` to push the new value
  to every hook.
- **a disabled hook** — GitHub auto-disables a hook after repeated delivery
  failures. `status` reports `disabled`.

All three are silent from the issue queue's side. Two independent things catch
them anyway, and neither needs this command: `MergedPullRequestSweeper` adopts
merged PRs hourly, and the `issues_stuck_claimed` invariant fires on an issue
claimed longer than a week whose PR has merged (both ISS-534).

`status` is the direct answer, though — the one that names the cause instead of
the symptom.
