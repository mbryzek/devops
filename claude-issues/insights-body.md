## How this pipeline works

Insights are the platform's generated, reviewed recommendations for a club. An issue in this
category is a **quality** complaint about that generation — a defect an admin found while
reviewing an insight in playbook-admin (wrong section content, a miscomputed metric, a rendering
problem, or a generation bug), or the feedback an admin left when rejecting a proposed checklist
item. The fix is almost never a one-off data patch; it is an improvement to how insights are
generated, so this routes to the insight-generation improvement session.

- **Generation (backend)**: repo `mbryzek/platform`, subproject `playbook/` (Scala 3 / Play).
  A run is a multi-stage processor chain under `playbook/app/playbook/processor/`:
  `QueueInsightRunsProcessor` → `PrepareInsightRunProcessor` → `InvestigateInsightProcessor` →
  `SynthesizeInsightProcessor` → `JudgeInsightProcessor` → `ReviseInsightProcessor` →
  `VerifyInsightClaimsProcessor`, with `SendInsightNotificationProcessor` /
  `SendPendingInsightsDigestProcessor` for delivery. Admin feedback feeds back through
  `FixInsightSectionProcessor` and `GeneralizeInsightFeedbackProcessor`. Supporting services:
  `playbook/app/playbook/services/Insight*.scala` (`InsightMemberReports`, `InsightReportCsv`,
  `InsightSectionChatService`).
- **Contract**: `spec/playbook-insight.json` — both sides regenerate from it, so a field that
  is wrong or missing on a reviewed insight is often a spec question. Insight data lives in the
  `playbook` schema (`insights`, `insight_runs`, `insight_sections`, `insight_reviews`,
  `insight_judgments`, `checklist_item_insights`, ...).
- **Review (frontend)**: repo `mbryzek/playbook-admin` (SvelteKit + Tailwind) — where an admin reads an
  insight, votes on sections, and accepts/rejects proposed checklist items. A "rendering" or
  "wrong section content" complaint may be the console, but is more often the generated content
  itself.
- **Principle**: members insights are **population-first** — the finding is about the member
  population as a whole; named members are supporting evidence, not the headline. Every ask of
  people should be paired with a concrete offer the model proposes. Judge content against that.

## Decoding the issue

- The **title** is the admin's one-line complaint; the **body** carries what they typed when
  reviewing or rejecting. For a rejected checklist item, the body is the rejection feedback —
  that is the signal for what "good" should have looked like.
- **Attachments are ground truth.** An in-app capture uploads the automatic screenshot first,
  with the page url (the exact insight/section the admin was viewing) and viewport in its
  description. Curl every attachment url into your working dir and LOOK before theorizing —
  local session DBs are schema-only (no prod rows) and you must NEVER touch the production DB.
- **Trace the defect to its stage.** Wrong section content or a bad recommendation → the
  synthesis/revision prompts and the investigate stage that fed them. A miscomputed metric →
  the aggregate/service the stage read from (fix the computation, not the rendered number). A
  rendering bug → the playbook-admin insight page.
- **Club** (when present) is the club whose insight was under review — reproduce against that
  club's shape of data.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first
   (`scala.general.mdc`, `scala.daos.mdc`, `scala.test.helpers.mdc`, `database.general.mdc`,
   and `apibuilder.general.mdc` if the contract changes; `elm.*.mdc` for a console fix).
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-insight-<date>`);
   clone `platform` (plus `playbook-admin` if the fix is in the console, and `platform-postgresql`
   for any schema change). Never edit `~/code/platform` or `~/code/playbook-admin` directly.
3. Group related issues into one branch/PR — one root cause, one fix.
4. Verify: a scoped `sbt` spec that FAILS without your fix, run against the isolated Docker
   session DB (`eval "$(~/code/devops/bin/claude-db start | grep '^CONF_DB_DEV_URL=' | sed
   's/^/export /')"`), never Mike's `:5432` and never production. For a console change, the Elm
   build plus `./review.sh`. Any API Builder spec change needs explicit approval on the exact
   JSON before you implement it.
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
