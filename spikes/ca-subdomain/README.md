# SP-A spike — Cloudflare wildcard Worker for `*.clubaid.co`

Throwaway artifacts from the ClubAid per-club-subdomains infra spike (SP-A). These prove
the wildcard owner-app routing for the club-subdomains program. Full findings live in
`~/code/claude/plans/clubaid-club-subdomains-design.md` → "SP-A Findings".

## What this proved (live on the `clubaid.co` zone, 2026-05-30)
- A **single Worker** on the wildcard route `*.clubaid.co/*` serves every club subdomain
  with **zero per-host setup** (`alpha`/`bravo.clubaid.co` → same Worker, host-derived id).
- **Wildcard TLS** is free via Cloudflare Universal SSL (cert SAN `*.clubaid.co`, one level
  deep — clubs are one level).
- **Route precedence (the key finding):** a wildcard Worker route **takes precedence over a
  Pages custom domain** — it hijacked `admin.clubaid.co` until a more-specific route was
  added. The deterministic fix is **specific routes win by specificity**
  (`admin.clubaid.co/*` beats `*.clubaid.co/*`). Cloudflare rejects an empty/"disable" route
  (`code 10019`), so reserved hosts need a real Worker on their specific route.

## Worker precedence model (production target — Option A)
| Route | Worker | Purpose |
|---|---|---|
| `admin.clubaid.co/*` | admin app (SP-B: as a Worker) | staff console — **must** be Worker-routed before the wildcard goes live |
| `www.clubaid.co/*` | (SP-B: native Single Redirect rule) | 301 → apex `clubaid.co` |
| `*.clubaid.co/*` | owner app | every club subdomain |
| apex `clubaid.co` | marketing | **not** matched by the wildcard — no special handling |

## Contents
- `owner-worker/` — echoes host + derived club label; bound to `*.clubaid.co/*`. Models the
  owner app's `event.url.host` → tenant resolution.
- `reserved-worker/` — the stopgap that keeps reserved hosts working while the wildcard is
  live: proxies `admin.clubaid.co` → `clubaid.pages.dev`, 301s `www.clubaid.co` → apex.
  **SP-B replaces this** by deploying the real admin app as a Worker + a native www redirect.

## Deploy (reference)
`wrangler deploy` from each dir (reads its `wrangler.toml`). Requires Workers write; the
wildcard DNS record (`AAAA * → 100::`, proxied) requires a separate `Zone:DNS:Edit` token.

## SP-B (production)
SP-B (plan: `~/code/claude/plans/2026-05-30-ca-repo-split-sp-b.md`) replaces the
`clubaid-reserved-spike` stopgap (`reserved-worker/` above): it deploys the admin app as a
Worker on the specific route `admin.clubaid.co/*` plus a native www→apex redirect, and
deploys the owner app as a Worker (its wildcard `*.clubaid.co/*` route is bound later in
SP-E).
