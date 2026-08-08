#!/usr/bin/env ruby
require 'minitest/autorun'
require 'json'
require_relative 'test_helper'
require 'agent/merge_lane'

# The merge lane (ISS-754).
#
# Every guarantee this system has about what may be merged lives in
# `Agent::MergeLane.verdict` and nowhere else — there is no branch protection, no
# ruleset, and no required check at the GitHub layer, so `gh pr merge` on a red
# PR succeeds and only this code stops it. That is why the arms are tested one by
# one rather than through a couple of happy paths: each of them was added for a
# reason, and a `case` that silently loses an arm merges exactly the thing that
# arm existed to refuse.
#
# The pure half needs no network. The two reads that do (`compare_status`,
# `open_prs`) go through Agent::Shell.capture, which `stub_shell` replaces.
class TestAgentMergeLane < Minitest::Test
  include DevTestSupport

  ML = Agent::MergeLane

  # A PR that passes every check, so each test can break exactly one thing and
  # know that is what the verdict is about.
  def green_pr(overrides = {})
    {
      "number" => 41, "title" => "ISS-700: do a thing", "url" => "https://github.com/mbryzek/platform/pull/41",
      "state" => "OPEN", "isDraft" => false, "isCrossRepository" => false,
      "createdAt" => "2026-08-01T00:00:00Z",
      "headRefName" => "i700_abc", "headRefOid" => "a" * 40, "baseRefName" => "main",
      "mergeStateStatus" => "CLEAN",
      "statusCheckRollup" => [check_run("ci", "SUCCESS", sha: "a" * 40)],
      "additions" => 10, "deletions" => 2, "files" => [{ "path" => "src/app.ts" }],
    }.merge(overrides)
  end

  # `detailsUrl` is GitHub's permanent run page for the check. Defaulted to one
  # rather than left out, because that is what every real CheckRun carries.
  def check_run(name, conclusion, sha: "a" * 40, status: "COMPLETED",
                details_url: "https://github.com/mbryzek/platform/actions/runs/1/job/2")
    { "__typename" => "CheckRun", "name" => name, "status" => status,
      "conclusion" => conclusion, "headSha" => sha, "detailsUrl" => details_url }
  end

  # Reviewable posts a StatusContext, not a CheckRun, and it names its fields
  # differently. Both shapes arrive through the same array.
  #
  # `targetUrl` defaults to "" because that is what gh returns for a status
  # nobody gave one to, and the fleet verify job gives none.
  def status_context(context, state, target_url: "")
    { "__typename" => "StatusContext", "context" => context, "state" => state,
      "targetUrl" => target_url }
  end

  def verdict(pr, repo: "mbryzek/platform", base_status: "ahead")
    ML.verdict(pr, repo: repo, base_status: base_status)
  end

  # ---- the happy path, so every other test's failure means something ---------

  def test_a_green_up_to_date_pr_is_mergeable
    v = verdict(green_pr)
    assert_equal :mergeable, v.code
    assert_equal :merge, v.action
  end

  # ---- the skips ------------------------------------------------------------

  # Not "a devops PR is classified irreversible" — classified and skipped are
  # different outcomes, and `decide ... && gh pr merge` is one shell line. The
  # only reliable way never to merge something is never to reach the merge
  # (ISS-660).
  def test_a_self_deploying_repo_is_skipped_before_anything_else_is_asked
    v = verdict(green_pr, repo: "mbryzek/devops")
    assert_equal :self_deploying_repo, v.code
    assert_equal :skip, v.action
    assert_match(/fast-forward/, v.message)
  end

  # The repo guard is checked before `state`, so even a PR that is wrong in some
  # other way reports the repo as the reason. Anything else would let a devops PR
  # look like an ordinary skip in the summary.
  def test_the_self_deploying_guard_outranks_every_other_reason
    assert_equal :self_deploying_repo,
                 verdict(green_pr("isDraft" => true, "state" => "CLOSED"), repo: "mbryzek/devops").code
  end

  def test_a_draft_is_skipped
    assert_equal :draft, verdict(green_pr("isDraft" => true)).code
  end

  def test_a_closed_pr_is_skipped
    assert_equal :not_open, verdict(green_pr("state" => "MERGED")).code
  end

  def test_a_fork_pr_is_skipped
    assert_equal :fork, verdict(green_pr("isCrossRepository" => true)).code
  end

  # The prefix is what ties a merge back to a tracked issue for `dev issues
  # reconcile` and the deploy reconcilers. A PR without one has nothing they can
  # follow, so it does not land here.
  def test_a_pr_without_the_issue_prefix_is_skipped
    assert_equal :no_issue_prefix, verdict(green_pr("title" => "fix the thing")).code
    assert_equal :no_issue_prefix, verdict(green_pr("title" => "ISS-700 no colon")).code
    assert_equal :mergeable, verdict(green_pr("title" => "ISS-1234: fine")).code
  end

  # ---- CI, which is the whole reason the lane exists ------------------------

  # THE enrolment rule. A repo with no workflow has no `ci` entry on its PRs, so
  # it merges nothing — and that is deliberately not a hard-coded list of
  # CI-enabled repos, which would drift the first time a workflow was added.
  def test_a_pr_with_no_ci_check_merges_nothing
    v = verdict(green_pr("statusCheckRollup" => []))
    assert_equal ML::NO_CI, v.code
    assert_equal :skip, v.action
  end

  # An empty rollup and a rollup carrying only OTHER checks are the same fact.
  def test_an_unrelated_check_is_not_a_ci_verdict
    assert_equal ML::NO_CI, verdict(green_pr("statusCheckRollup" => [check_run("lint", "SUCCESS")])).code
  end

  def test_a_running_check_is_waited_on_not_skipped
    pr = green_pr("statusCheckRollup" => [check_run("ci", nil, status: "IN_PROGRESS")])
    v = verdict(pr)
    assert_equal :ci_pending, v.code
    assert_equal :wait, v.action
  end

  # `park`, not `skip`: whether a red suite is this PR's fault or `main` was
  # already red is a judgment, and until CI has existed for a while in these
  # repos it is a live question every time.
  def test_a_failing_check_is_parked_for_a_judgment
    v = verdict(green_pr("statusCheckRollup" => [check_run("ci", "FAILURE")]))
    assert_equal :ci_failed, v.code
    assert_equal :park, v.action
    assert_match(/already red/, v.message)
  end

  # Anything that is not SUCCESS. CANCELLED, TIMED_OUT, ACTION_REQUIRED and
  # NEUTRAL are all "CI did not pass", and a lane that enumerated only FAILURE
  # would merge the rest.
  def test_every_non_success_conclusion_is_a_failure
    %w[CANCELLED TIMED_OUT ACTION_REQUIRED NEUTRAL SKIPPED STALE].each do |conclusion|
      assert_equal :ci_failed, verdict(green_pr("statusCheckRollup" => [check_run("ci", conclusion)])).code,
                   "conclusion #{conclusion} must not read as a pass"
    end
  end

  # THE FRESH INVARIANT. A green attached to an earlier push is not a green for
  # what `gh pr merge --squash` is about to replay.
  def test_a_check_that_ran_on_an_older_commit_is_stale_not_green
    pr = green_pr("headRefOid" => "b" * 40,
                  "statusCheckRollup" => [check_run("ci", "SUCCESS", sha: "a" * 40)])
    v = verdict(pr)
    assert_equal :ci_stale, v.code
    assert_equal :wait, v.action
  end

  # A rollup entry with no sha on it cannot be proven stale, and the lane does not
  # invent a failure it did not observe — the AHEAD invariant below still has to
  # pass, so the guarantee is not lost, only this half of it.
  def test_a_check_with_no_sha_falls_through_to_the_base_check
    pr = green_pr("statusCheckRollup" => [{ "name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS" }])
    assert_equal :mergeable, verdict(pr).code
  end

  def test_the_ci_check_name_is_matched_case_insensitively
    assert_equal :mergeable, verdict(green_pr("statusCheckRollup" => [check_run("CI", "SUCCESS")])).code
  end

  # ---- the base, which is the other half of "in the state it lands in" ------

  def test_a_pr_behind_main_needs_its_base_brought_under_it
    v = verdict(green_pr, base_status: "behind")
    assert_equal :needs_update, v.code
    assert_equal :update, v.action
  end

  def test_a_diverged_pr_needs_its_base_brought_under_it
    assert_equal :needs_update, verdict(green_pr, base_status: "diverged").code
  end

  # ISS-769. The action a session reads is the act it will attempt, so it must
  # name the one that is actually sanctioned: `dev agent update-branch` merges
  # the base in server-side, and nothing here rebases or pushes. `:rebase` named
  # work that `agent/instructions.md` §3 forbids to every session.
  def test_no_action_names_a_rebase
    refute_includes ML::ACTIONS, :rebase,
                    "a rebase of a PR branch is a force-push, which no session may perform"
    assert_includes ML::ACTIONS, :update
  end

  def test_the_update_verdict_points_at_the_command_that_may_perform_it
    assert_includes verdict(green_pr, base_status: "behind").message, "dev agent update-branch"
  end

  def test_an_identical_head_is_mergeable
    assert_equal :mergeable, verdict(green_pr, base_status: "identical").code
  end

  # A `gh` blip must never read as "up to date". Unknown holds the PR.
  def test_an_uncomparable_base_holds_the_pr_rather_than_assuming
    v = verdict(green_pr, base_status: nil)
    assert_equal :base_unknown, v.code
    assert_equal :wait, v.action
  end

  # ---- the review deferral --------------------------------------------------

  def test_a_pending_reviewable_context_defers
    pr = green_pr("statusCheckRollup" => [check_run("ci", "SUCCESS"),
                                          status_context("code-review/reviewable", "PENDING")])
    v = verdict(pr)
    assert_equal :review_in_flight, v.code
    assert_equal :defer, v.action
  end

  # A review Mike finished is not a review in flight.
  def test_a_successful_reviewable_context_does_not_defer
    pr = green_pr("statusCheckRollup" => [check_run("ci", "SUCCESS"),
                                          status_context("code-review/reviewable", "SUCCESS")])
    assert_equal :mergeable, verdict(pr).code
  end

  # A red PR that is ALSO under review verdicts as RED, not as deferred: the
  # deferred list in the run summary means "PRs this loop would have merged and
  # deliberately left you", and a red one would not have merged. The review is
  # not lost — `review_in_flight` is carried on the Candidate independently of
  # the verdict, which is what makes the ordering safe (ISS-663).
  def test_a_red_pr_under_review_verdicts_as_red_but_still_reports_the_review
    pr = green_pr("statusCheckRollup" => [check_run("ci", "FAILURE"),
                                          status_context("code-review/reviewable", "PENDING")])
    candidate = ML.candidate("mbryzek/platform", pr)
    assert_equal :ci_failed, candidate.verdict.code
    assert candidate.review_in_flight, "a red PR under review must still report the review"
  end

  # ---- the cross-repo arm (ISS-758) ----------------------------------------

  # The one fact a per-PR check structurally cannot see. This PR is green, fresh,
  # ahead of main and unreviewed — everything the lane asks for — and it still
  # must not merge, because its producer in another repo has not shipped.
  def test_a_sibling_hold_stops_an_otherwise_mergeable_pr
    v = ML.verdict(green_pr, repo: "mbryzek/playbook-admin", base_status: "ahead",
                   sibling_hold: "platform#2133 merged but has not deployed")
    assert_equal :waits_on_sibling, v.code
    assert_equal :wait, v.action
    assert_match(/has not deployed/, v.message)
  end

  # Nothing was passed and nothing changes: every caller and every test that
  # predates ISS-758 asks exactly the question it asked before.
  def test_no_sibling_hold_leaves_the_verdict_untouched
    assert_equal :mergeable, ML.verdict(green_pr, repo: "mbryzek/platform", base_status: "ahead").code
    assert_equal :mergeable, ML.verdict(green_pr, repo: "mbryzek/platform", base_status: "ahead",
                                        sibling_hold: nil).code
    assert_equal :mergeable, ML.verdict(green_pr, repo: "mbryzek/platform", base_status: "ahead",
                                        sibling_hold: "").code
  end

  # A red PR held by a sibling verdicts as RED. Same ordering argument as the
  # review deferral above: `:waits_on_sibling` says "this would merge as soon as
  # its producer ships", and a red PR would not.
  def test_a_red_pr_with_a_sibling_hold_still_verdicts_as_red
    pr = green_pr("statusCheckRollup" => [check_run("ci", "FAILURE")])
    v = ML.verdict(pr, repo: "mbryzek/playbook-admin", base_status: "ahead",
                   sibling_hold: "platform#2133 has not merged")
    assert_equal :ci_failed, v.code
  end

  # The lane asks per PR, and it must ask about THIS PR — an off-by-one in the
  # lookup would hold the wrong one and let the held one through. Asked ONCE,
  # too: `candidate` verdicts twice when the base is unknown, and re-asking there
  # would double every caller's cost for an answer that cannot have changed.
  def test_the_candidate_asks_the_hold_once_about_its_own_repo_and_number
    asked = []
    hold = ->(repo, number) { asked << [repo, number]; "platform#1 has not merged" }
    candidate = ML.candidate("mbryzek/playbook-admin", green_pr, sibling_hold: hold)
    assert_equal [["mbryzek/playbook-admin", 41]], asked
    assert_equal :waits_on_sibling, candidate.verdict.code
  end

  # `mergeStateStatus` is deliberately NOT the source for the review deferral:
  # UNSTABLE is the same fact, but the field also reports DIRTY, BEHIND and
  # UNKNOWN, and skipping on "not CLEAN" would fold three unrelated states in.
  def test_an_unstable_merge_state_alone_does_not_defer
    assert_equal :mergeable, verdict(green_pr("mergeStateStatus" => "UNSTABLE")).code
  end

  def test_a_conflicting_pr_asks_for_a_resolution
    v = verdict(green_pr("mergeStateStatus" => "DIRTY"))
    assert_equal :conflicts, v.code
    assert_equal :resolve, v.action
  end

  # ---- reversibility --------------------------------------------------------

  def test_a_migration_is_irreversible
    assert_equal "irreversible", ML.reversibility(["scripts/20260806-add-column.sql"], repo: "platform-postgresql")
    assert_equal "irreversible", ML.reversibility(["db/migrations/001.sql"], repo: "platform")
    assert_equal "irreversible", ML.reversibility(["dao/spec/club.json"], repo: "platform")
  end

  # The class is a property of the repo's DEPLOY PATH, not of the changed files:
  # a one-word README fix in a repo that deploys itself is still irreversible.
  def test_a_self_deploying_repo_is_irreversible_whatever_it_touches
    assert_equal "irreversible", ML.reversibility(["README.md"], repo: "mbryzek/devops")
  end

  # A spec change is classified by apibuilder's own diff, and the DEFAULT is the
  # path-grep answer this replaced: a caller that did not compute the diff gets
  # `costly`, exactly as before (ISS-757). Over-classifying costs a merge that
  # waits; under-classifying ships a broken client.
  def test_a_spec_change_is_costly_unless_apibuilder_says_otherwise
    paths = ["spec/club.json", "app/Foo.scala"]
    assert_equal "costly", ML.reversibility(paths, repo: "platform")
    assert_equal "costly", ML.reversibility(paths, repo: "platform", spec_diff: :unknown)
    assert_equal "costly", ML.reversibility(paths, repo: "platform", spec_diff: :breaking)
    assert_equal "reversible", ML.reversibility(paths, repo: "platform", spec_diff: :non_breaking)
  end

  # A non-breaking API spec does not make the migration beside it revertible.
  def test_a_non_breaking_spec_never_softens_a_migration
    assert_equal "irreversible",
                 ML.reversibility(["spec/club.json", "dao/spec/db-club.json"], repo: "platform",
                                                                              spec_diff: :non_breaking)
    assert_equal "irreversible",
                 ML.reversibility(["spec/club.json"], repo: "mbryzek/devops", spec_diff: :non_breaking)
  end

  # `api diff` reports three states and each one has to survive the trip: an exit
  # code this does not recognise is `:unknown`, never a pass.
  def test_the_spec_diff_exit_codes_map_to_the_three_verdicts
    assert_equal :non_breaking, ML::SPEC_DIFF_EXIT[0]
    assert_equal :breaking, ML::SPEC_DIFF_EXIT[1]
    assert_equal :unknown, ML::SPEC_DIFF_EXIT[2]
    assert_equal :unknown, ML::SPEC_DIFF_EXIT.fetch(127, :unknown)
  end

  # The clone is only worth doing for a PR that changed a contract.
  def test_only_a_spec_change_is_worth_a_clone
    assert ML.spec_touched?(["spec/club.json"])
    refute ML.spec_touched?(["app/Foo.scala", "dao/spec/db-club.json"])
    refute ML.spec_touched?(nil)
  end

  # The lane's trust model in one test: there is no way to TELL it a spec change
  # is safe. `spec_diff` takes a repo and a PR number and computes the answer
  # itself, so a session asking for a merge cannot assert its way past the check.
  def test_the_spec_verdict_cannot_be_asserted_by_the_caller
    assert_equal %i[repo number], ML.method(:spec_diff).parameters.select { |kind, _| kind == :req }.map(&:last)
    refute ML.method(:spec_diff).parameters.any? { |kind, name| kind == :key && name == :verdict }
    assert_equal :unknown, ML.spec_diff("mbryzek/platform", "")
  end

  def test_documentation_only_is_trivial
    assert_equal "trivial", ML.reversibility(["README.md", "docs/design.md"], repo: "platform")
  end

  def test_ordinary_code_is_reversible
    assert_equal "reversible", ML.reversibility(["src/lib/x.ts", "src/lib/x.test.ts"], repo: "playbook-admin")
  end

  # An empty file list is not "all documentation". `[].all?` is true, and a PR
  # whose files could not be read must not classify as the most permissive class
  # there is.
  def test_an_unreadable_file_list_is_not_trivial
    assert_equal "reversible", ML.reversibility([], repo: "platform")
    assert_equal "reversible", ML.reversibility(nil, repo: "platform")
  end

  # ---- the assertions the ledger is handed ----------------------------------

  def test_assertions_are_computed_from_the_diff
    candidate = ML.candidate("mbryzek/platform", green_pr("files" => [{ "path" => "spec/club.json" }]))
    a = ML.assertions(candidate, base_sha: "c" * 40)
    assert_equal "platform", a["repo"]
    assert_equal 12, a["diff_lines"]
    assert_equal true, a["touches_spec"]
    assert_equal false, a["touches_migration"]
    assert_equal false, a["touches_secrets"]
    assert_equal "c" * 40, a["base_sha"]
  end

  # The verdict is recorded beside `touches_spec` so the feed says WHY a spec PR
  # was allowed through — and defaults to `unknown` rather than to a pass.
  def test_the_spec_verdict_is_recorded_only_when_a_spec_changed
    spec_pr = ML.candidate("mbryzek/platform", green_pr("files" => [{ "path" => "spec/club.json" }]))
    assert_equal "non_breaking", ML.assertions(spec_pr, spec_diff: :non_breaking)["spec_diff"]
    assert_equal "unknown", ML.assertions(spec_pr)["spec_diff"]

    code_pr = ML.candidate("mbryzek/platform", green_pr("files" => [{ "path" => "app/Foo.scala" }]))
    refute ML.assertions(code_pr).key?("spec_diff")
  end

  # `suite_passed_post_rebase` is the ledger's existing field name and it means
  # something different here than it did in the playbook loop: not "this session
  # ran the suite" but "GitHub Actions did". `verified_by` is what says so, and
  # it is the whole trust argument in one assertion.
  def test_assertions_name_who_actually_verified
    a = ML.assertions(ML.candidate("mbryzek/platform", green_pr))
    assert_equal true, a["suite_passed_post_rebase"]
    assert_equal "github_actions:ci", a["verified_by"]
  end

  def test_secrets_are_reported
    candidate = ML.candidate("mbryzek/platform", green_pr("files" => [{ "path" => "conf/.env.production" }]))
    assert_equal true, ML.assertions(candidate)["touches_secrets"]
  end

  # ---- where the evidence is (ISS-1080) -------------------------------------

  # Naming the verifier and stopping there left an auditor to go back to GitHub
  # for the link. A CheckRun already carries it: `detailsUrl` is a permanent run
  # page anyone can open, and it belongs on the decision.
  def test_a_check_runs_run_page_is_recorded_as_the_evidence
    pr = green_pr("statusCheckRollup" => [check_run("ci", "SUCCESS", details_url: "https://example.test/run/7")])
    a = ML.assertions(ML.candidate("mbryzek/platform", pr))
    assert_equal "https://example.test/run/7", a["verified_url"]
  end

  # The other producer's link, under the other name. Both shapes arrive through
  # the same array and neither `detailsUrl` nor `targetUrl` is on both.
  def test_a_commit_statuss_target_url_is_recorded_as_the_evidence
    pr = green_pr("statusCheckRollup" => [status_context("ci", "SUCCESS", target_url: "https://example.test/build/9")])
    a = ML.assertions(ML.candidate("mbryzek/platform", pr))
    assert_equal "https://example.test/build/9", a["verified_url"]
  end

  # What the fleet verify job actually posts: a commit status with no
  # `target_url` at all. The key is dropped rather than recorded as "" — an
  # assertion whose value is an empty string reads, in a feed, as a link that
  # broke.
  def test_a_status_with_no_link_records_no_evidence_url
    pr = green_pr("statusCheckRollup" => [status_context("ci", "SUCCESS")])
    refute ML.assertions(ML.candidate("mbryzek/platform", pr)).key?("verified_url")
  end

  # A link to a run that did not verify the commit about to land is worse than
  # no link: an auditor would follow it. `ci_stale` is the sharpest case — there
  # IS a green run page, and it is evidence about a tree nobody is merging.
  def test_a_stale_green_leaves_no_evidence_url
    pr = green_pr("statusCheckRollup" => [check_run("ci", "SUCCESS", sha: "b" * 40)])
    assert_nil ML.candidate("mbryzek/platform", pr).verified_url
  end

  def test_a_red_or_absent_check_leaves_no_evidence_url
    red = green_pr("statusCheckRollup" => [check_run("ci", "FAILURE")])
    assert_nil ML.verified_url(red)
    assert_nil ML.verified_url(green_pr("statusCheckRollup" => []))
  end

  # For a fleet-verified repo the description IS the whole trail — the log it
  # names is a local file on the runner that built the sha, and nothing else
  # records which runner that was.
  def test_the_commit_status_description_is_recorded_as_the_evidence
    detail = "passed in 0.9m [Mac] /Users/x/Library/Logs/dev-agent/ci/playbook-admin-80a39f65092e/build.log"
    a = ML.assertions(ML.candidate("mbryzek/platform", green_pr), verified_detail: detail)
    assert_equal detail, a["verified_detail"]
  end

  # Every way of not having one collapses to the same dropped key: not asked for,
  # asked for and unset (`gh --jq` prints the literal `null`), or asked for on a
  # repo GitHub Actions verifies, where there is no commit status to describe.
  def test_a_missing_description_records_no_evidence_detail
    candidate = ML.candidate("mbryzek/platform", green_pr)
    refute ML.assertions(candidate).key?("verified_detail")
    refute ML.assertions(candidate, verified_detail: "  ").key?("verified_detail")
  end

  def test_the_commit_status_description_is_read_from_the_status_api
    seen = nil
    stub_shell(lambda { |cmd, _opts|
      seen = cmd
      shell_result(output: "passed in 0.9m [Mac] /tmp/build.log\n")
    }) do
      assert_equal "passed in 0.9m [Mac] /tmp/build.log",
                   ML.verified_detail("playbook-admin", "a" * 40)
    end
    # Asked of the qualified slug even though the caller gave a bare name: a 404
    # here would drop the evidence silently rather than fail anything.
    assert_includes seen.join(" "), "repos/mbryzek/playbook-admin/commits/#{'a' * 40}/status"
  end

  # A CheckRun-verified repo has no `ci` commit status, so `--jq` matches nothing
  # and prints an empty body. That is "no detail", never an empty assertion.
  def test_no_commit_status_leaves_no_evidence_detail
    stub_shell(->(_cmd, _opts) { shell_result(output: "") }) do
      assert_nil ML.verified_detail("mbryzek/playbook-app", "a" * 40)
    end
    stub_shell(->(_cmd, _opts) { shell_result(output: "null\n") }) do
      assert_nil ML.verified_detail("mbryzek/playbook-app", "a" * 40)
    end
    stub_shell(->(_cmd, _opts) { shell_result(output: "boom", exitstatus: 1) }) do
      assert_nil ML.verified_detail("mbryzek/playbook-app", "a" * 40)
    end
  end

  # ---- the lane order -------------------------------------------------------

  # The head of the line is the oldest PR that may merge RIGHT NOW, not the
  # oldest PR. A lane that stopped dead behind a red PR would merge nothing for
  # as long as its author took to fix it, while the PRs behind it are
  # independently green.
  def test_the_head_of_line_skips_blocked_prs
    stub_shell(->(_cmd, _opts) { shell_result(output: "ahead") }) do
      blocked = ML.candidate("mbryzek/platform", green_pr("number" => 1, "isDraft" => true))
      ready = ML.candidate("mbryzek/platform", green_pr("number" => 2))
      assert_equal 2, ML.head_of_line([blocked, ready]).number
    end
  end

  def test_the_head_of_line_is_nil_when_nothing_may_merge
    assert_nil ML.head_of_line([ML.candidate("mbryzek/platform", green_pr("isDraft" => true))])
  end

  # First in, first out. Picking by anything else is how the oldest branch keeps
  # losing and going staler, which is the cost this epic exists to remove.
  def test_open_prs_come_back_oldest_first
    rows = [green_pr("number" => 9, "createdAt" => "2026-08-05T00:00:00Z"),
            green_pr("number" => 3, "createdAt" => "2026-08-01T00:00:00Z")]
    stub_shell(->(_cmd, _opts) { shell_result(output: JSON.generate(rows)) }) do
      assert_equal [3, 9], ML.open_prs("mbryzek/platform").map { |pr| pr["number"] }
    end
  end

  # A `gh` failure is an empty lane, never a lane full of unverdicted PRs.
  def test_a_failed_list_is_an_empty_lane
    stub_shell(->(_cmd, _opts) { shell_result(output: "boom", exitstatus: 1) }) do
      assert_empty ML.open_prs("mbryzek/platform")
    end
  end

  # The expensive compare call is only made once a PR has survived every cheaper
  # check — a repo of 23 open PRs of which 20 are drafts has no reason to make 23
  # API calls.
  def test_the_base_comparison_is_not_asked_for_a_pr_that_already_failed
    calls = []
    stub_shell(lambda { |cmd, _opts|
      calls << cmd
      shell_result(output: "ahead")
    }) do
      ML.candidate("mbryzek/platform", green_pr("isDraft" => true))
    end
    assert_empty calls, "a draft must not cost a compare call"
  end

  def test_the_base_comparison_is_asked_for_a_pr_that_needs_it
    stub_shell(lambda { |cmd, _opts|
      assert_includes cmd.join(" "), "compare/main...#{'a' * 40}"
      shell_result(output: "ahead\n")
    }) do
      assert_equal :mergeable, ML.candidate("mbryzek/platform", green_pr).verdict.code
    end
  end

  # ---- the permission boundary ----------------------------------------------

  # LANE_REPOS is a ceiling, not a work list. `repos: unrestricted` on the
  # envelope means the ledger will not narrow the list — it is not an instruction
  # to walk every repo under the account (ISS-660).
  def test_the_lane_never_contains_a_self_deploying_repo
    ML::SELF_DEPLOYING_REPOS.each do |repo|
      refute_includes ML::LANE_REPOS, repo,
                      "#{repo} deploys itself and must not be in the lane's permission boundary"
    end
  end

  def test_in_lane_accepts_bare_and_qualified_names
    assert ML.in_lane?("platform")
    assert ML.in_lane?("mbryzek/platform")
    refute ML.in_lane?("devops")
    refute ML.in_lane?("mbryzek/devops")
  end

  # A repo under a different owner that happens to share a name is not ours.
  def test_in_lane_rejects_another_owners_repo_of_the_same_name
    refute ML.in_lane?("someoneelse/platform")
  end

  def test_qualify_is_idempotent
    assert_equal "mbryzek/platform", ML.qualify("platform")
    assert_equal "mbryzek/platform", ML.qualify("mbryzek/platform")
  end

  # ---- the merge itself -----------------------------------------------------

  # The second, independent refusal. `verdict` already refuses this repo; a
  # future caller that forgets to check the verdict must still not be able to
  # deploy the fleet.
  def test_merge_refuses_a_self_deploying_repo_even_when_asked_directly
    called = false
    stub_shell(->(_cmd, _opts) { called = true; shell_result }) do
      assert_raises(ArgumentError) { ML.merge!("mbryzek/devops", 7, head_sha: "a" * 40) }
    end
    refute called, "the devops guard must fire before any subprocess is spawned"
  end

  # `--match-head-commit` is what makes the lane atomic against the one race it
  # cannot otherwise close: a push landing between the verdict and the merge.
  # Without it, `gh pr merge` would happily squash a commit nothing verified.
  def test_merge_pins_the_head_commit_it_verified
    seen = nil
    stub_shell(->(cmd, _opts) { seen = cmd; shell_result }) do
      ML.merge!("mbryzek/platform", 41, head_sha: "a" * 40)
    end
    assert_includes seen, "--match-head-commit"
    assert_includes seen, "a" * 40
    assert_includes seen, "--squash"
    assert_includes seen, "--delete-branch"
  end

  def test_merge_refuses_without_a_head_sha
    called = false
    stub_shell(->(_cmd, _opts) { called = true; shell_result }) do
      assert_raises(ArgumentError) { ML.merge!("mbryzek/platform", 41, head_sha: "") }
    end
    refute called
  end

  # ---- bringing the base under a PR (ISS-769) -------------------------------

  def update_command
    seen = nil
    stub_shell(->(cmd, _opts) { seen = cmd; shell_result }) do
      ML.update_branch!("mbryzek/platform", 41, head_sha: "a" * 40)
    end
    seen
  end

  # THE reason this act is allowed at all. GitHub's update-branch REST endpoint
  # merges the base into the head server-side; it has no rebase mode, so nothing
  # in this call can rewrite the branch. A `git push --force` or a `gh pr
  # update-branch --rebase` here would be the exact act `agent/instructions.md`
  # §3 forbids, and the boundary must be the endpoint rather than a comment.
  def test_the_update_is_a_server_side_merge_and_never_a_push
    cmd = update_command.join(" ")
    assert_includes cmd, "--method PUT"
    assert_includes cmd, "repos/mbryzek/platform/pulls/41/update-branch"
    refute_includes cmd, "--rebase"
    refute_includes cmd, "push"
    refute_includes cmd, "--force"
  end

  # `--match-head-commit` for this call. Without it a push landing between the
  # verdict and here would have the base merged into a head nobody looked at.
  # Verified against the live API: a non-matching value comes back 422.
  def test_the_update_pins_the_head_commit_the_verdict_was_computed_from
    assert_includes update_command.join(" "), "expected_head_sha=#{'a' * 40}"
  end

  # The same second, independent refusal `merge!` carries. Updating a branch
  # deploys nothing, so this is not about the revert window — a self-deploying
  # repo is one the lane may not act on from ANY code path.
  def test_the_update_refuses_a_self_deploying_repo_even_when_asked_directly
    called = false
    stub_shell(->(_cmd, _opts) { called = true; shell_result }) do
      assert_raises(ArgumentError) { ML.update_branch!("mbryzek/devops", 7, head_sha: "a" * 40) }
    end
    refute called, "the devops guard must fire before any subprocess is spawned"
  end

  def test_the_update_refuses_without_a_head_sha
    called = false
    stub_shell(->(_cmd, _opts) { called = true; shell_result }) do
      assert_raises(ArgumentError) { ML.update_branch!("mbryzek/platform", 41, head_sha: "") }
    end
    refute called
  end

  # The ordering in `verdict` is load-bearing a second time (ISS-663 + ISS-769):
  # a PR a human is mid-pass over defers BEFORE the base is ever compared, so the
  # lane never moves a branch out from under a review in flight.
  def test_a_pr_under_review_is_never_verdicted_for_an_update
    pr = green_pr("statusCheckRollup" => [
      check_run("ci", "SUCCESS"),
      status_context(ML::REVIEW_CONTEXT, "PENDING"),
    ])
    assert_equal :review_in_flight, verdict(pr, base_status: "behind").code
  end

  # Nor is a red one: CI is checked before the base, so a PR whose suite is
  # failing parks rather than spending a CI run on a branch that is already red.
  def test_a_red_pr_is_never_verdicted_for_an_update
    pr = green_pr("statusCheckRollup" => [check_run("ci", "FAILURE")])
    assert_equal :ci_failed, verdict(pr, base_status: "behind").code
  end

  # And a conflicting one is left for its author (ISS-765). The endpoint would
  # refuse it anyway, but the lane must not ask.
  def test_a_conflicting_pr_is_never_verdicted_for_an_update
    assert_equal :conflicts, verdict(green_pr("mergeStateStatus" => "DIRTY"), base_status: "behind").code
  end
end
