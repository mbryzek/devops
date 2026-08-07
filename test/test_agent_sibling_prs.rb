#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-657: a run that produces SEVERAL independent PRs.
#
# The assignment pins one branch and says the executor classifies the outcome by
# looking it up; the review playbooks require independent, disjoint, unstacked
# PRs. Both cannot hold on one branch, and the ISS-651 run resolved it by
# improvising sibling branches (`i651_irv_sig`, `i651_irv_pub`, …) — correctly,
# but with five of its six PRs findable only by a human reading GitHub.
#
# The resolution is that the assigned branch is a NAMESPACE, so the three things
# under test here are the three that make that true end to end:
#
#   1. the CONTRACT says so, in the standing instructions and in the assignment
#      block beside the branch name (a session reads both and improvises when
#      they disagree, which is the whole failure);
#   2. the LOOKUP finds the family, not just the one branch;
#   3. the REAP records every PR it found, not just the one classification ranked
#      highest — a status write carries exactly one url, and everything not in
#      the fix list is invisible to `dev issues show` and to the reconciler.
class TestAgentSiblingPrs < Minitest::Test
  include DevTestSupport

  BRANCH = "i651_irv".freeze

  def pr(number:, head:, title: "ISS-651: fix it", state: "OPEN", draft: false)
    { "number" => number, "url" => "https://github.com/mbryzek/lakeviewsummit-ui/pull/#{number}",
      "title" => title, "state" => state, "isDraft" => draft, "headRefName" => head }
  end

  # ---- 1. the contract ----

  def instructions = File.read(Agent::Paths.instructions_file)

  # In §1, with the rest of the PR sequence: it is part of how a run ENDS, and a
  # session that has read §1 and stopped has read the rule that matters most.
  def test_the_multi_pr_rule_is_in_the_close_out_section_of_the_instructions
    section_one = instructions[/^## 1\. How this ends.*?^## 2\./m]
    refute_nil section_one, "instructions.md no longer has a §1 / §2 to place the rule between"
    assert_includes section_one, "### More than one PR: the assigned branch is a NAMESPACE"
    assert_includes section_one, "`<assigned>_<suffix>`"
    # Recording the extras is half the rule: sibling PRs nobody records are
    # exactly as invisible as sibling branches nobody can find.
    assert_includes section_one, "dev issues fix <n> --url"
  end

  # §4 is where a session looks for what to do with its branch, and it used to
  # say "verbatim, in every repo" with no exception at all.
  def test_the_workspace_section_points_at_the_rule
    section_four = instructions[/^## 4\. Your workspace.*?^## 5\./m]
    refute_nil section_four
    assert_includes section_four, "`<assigned>_<suffix>`"
  end

  def issue = { "number" => "651", "title" => "weekly code review", "category" => "improvement", "body" => "b" }

  # Beside the branch name itself, for the same reason "do not rename" is: the
  # assignment is what a session actually acts on, and a rule that lives only
  # 300 lines up loses to the imperative next to the name.
  def test_the_assignment_states_the_sibling_naming_rule
    text = Agent::Prompt.assignment(issue: issue, slug: BRANCH, workspace: "/ws/#{BRANCH}")
    assert_match(/#{BRANCH}_<suffix>/, text)
    assert_match(/dev issues fix 651 --url/, text)
    # …without softening the rule it qualifies.
    assert_match(/\*\*Do not rename the branch\.\*\*/, text)
  end

  # ---- 2. the lookup ----

  def test_a_sibling_branch_is_in_the_family_and_a_lookalike_is_not
    assert Agent::Github.in_branch_family?(pr(number: 36, head: BRANCH), BRANCH)
    assert Agent::Github.in_branch_family?(pr(number: 37, head: "#{BRANCH}_sig"), BRANCH)
    refute Agent::Github.in_branch_family?(pr(number: 38, head: "x_#{BRANCH}"), BRANCH),
           "the contract is a PREFIX — a branch that merely contains the name is somebody else's"
    refute Agent::Github.in_branch_family?(pr(number: 39, head: "i651_irvine"), BRANCH),
           "the separator is required, or every branch sharing a stem matches"
    refute Agent::Github.in_branch_family?(pr(number: 40, head: ""), BRANCH)
  end

  # Either handle alone is enough. A session that titled a PR wrong is still found
  # by its branch; one that named a branch wrong is still found by its title.
  def test_prs_for_issue_matches_the_branch_family_or_the_title_prefix
    listed = [pr(number: 36, head: BRANCH),
              pr(number: 37, head: "#{BRANCH}_sig", title: "no prefix at all"),
              pr(number: 38, head: "someone-elses-branch", title: "ISS-651: also mine"),
              pr(number: 39, head: "unrelated", title: "ISS-652: not mine")]
    found = stub_singleton(Agent::Github, :list_prs, ->(*) { listed }) do
      Agent::Github.prs_for_issue("mbryzek/lakeviewsummit-ui", BRANCH, "651")
    end
    assert_equal [36, 37, 38], found.map { |p| p["number"] }
  end

  # A number that is not one must not raise into the reap: the title half simply
  # does not apply and the branch family still answers.
  def test_a_non_numeric_issue_number_falls_back_to_the_branch_family
    listed = [pr(number: 36, head: BRANCH), pr(number: 39, head: "unrelated", title: "ISS-651: x")]
    found = stub_singleton(Agent::Github, :list_prs, ->(*) { listed }) do
      Agent::Github.prs_for_issue("mbryzek/lakeviewsummit-ui", BRANCH, nil)
    end
    assert_equal [36], found.map { |p| p["number"] }
  end

  # The exact-branch call and the broad scan overlap by construction, and the
  # reap turns this list into one fix per url.
  def test_prs_in_workspace_returns_every_pr_once
    primary = pr(number: 36, head: BRANCH)
    sibling = pr(number: 37, head: "#{BRANCH}_sig")
    Dir.mktmpdir do |ws|
      stubs = { repos_in_workspace: ->(*) { ["mbryzek/lakeviewsummit-ui"] },
                prs_on_branch: ->(*) { [primary] },
                list_prs: ->(*) { [primary, sibling] } }
      found = with_stubbed_github(stubs) { Agent::Github.prs_in_workspace(ws, BRANCH, "651") }
      assert_equal [36, 37], found.map { |p| p["number"] }
    end
  end

  # Equal states, and the sibling is the newer PR — so the plain "newest wins"
  # tie-break would record a sibling's url as the issue's fix and change which
  # one that is every time a session opens another. The assigned branch is where
  # the session put its most significant work; it wins.
  def test_the_pr_on_the_assigned_branch_wins_a_tie
    prs = [ready(36, BRANCH), ready(37, "#{BRANCH}_sig")]
    assert_equal 36, Agent::Github.primary_pr(prs, BRANCH)["number"]
    assert_equal 37, Agent::Github.primary_pr(prs)["number"], "with no branch to prefer, newest still wins"
  end

  # …but never over a stronger state. A merged sibling is delivered work and an
  # open primary is not.
  def test_a_merged_sibling_still_outranks_an_open_primary
    prs = [ready(36, BRANCH), pr(number: 37, head: "#{BRANCH}_sig", state: "MERGED")]
    assert_equal 37, Agent::Github.primary_pr(prs, BRANCH)["number"]
  end

  # `gh search prs` has a SMALLER --json field set than `gh pr list`, and
  # headRefName is one of the fields it does not have. Asking for it exits
  # non-zero, which `capture` reads as no output — so the fallback lookup would
  # find nothing at all, with no error anywhere. Verified against the real `gh`
  # while writing this; guarded here because the two lists look interchangeable.
  def test_the_search_fallback_never_asks_for_the_head_branch
    cmd = nil
    stub_singleton(Agent::Github, :capture, ->(c, **) { cmd = c; nil }) do
      Agent::Github.search("head:#{BRANCH}", owner: "mbryzek")
    end
    fields = cmd[cmd.index("--json") + 1]
    refute_includes fields, "headRefName"
    assert_includes fields, "state"
    assert_includes Agent::Github::PR_FIELDS, "headRefName", "…while `gh pr list` does ask for it"
  end

  # `dev issues reconcile` compares an app's live release against this, so the
  # field has to be asked for as well as read (ISS-737).
  def test_merged_at_reads_the_merge_time_of_a_merged_pr
    assert_includes Agent::Github::PR_FIELDS, "mergedAt"
    assert_equal "2026-08-06T15:41:05Z",
                 Agent::Github.merged_at(pr(number: 1, head: BRANCH, state: "MERGED").merge("mergedAt" => "2026-08-06T15:41:05Z"))
  end

  # An OPEN PR carries mergedAt: null, and a CLOSED-unmerged one does too — but
  # neither may ever answer with a time, whatever the field happens to hold.
  def test_merged_at_is_nil_for_anything_not_merged
    assert_nil Agent::Github.merged_at(pr(number: 1, head: BRANCH, state: "OPEN").merge("mergedAt" => nil))
    assert_nil Agent::Github.merged_at(pr(number: 1, head: BRANCH, state: "CLOSED").merge("mergedAt" => "2026-08-06T15:41:05Z"))
    assert_nil Agent::Github.merged_at(nil)
  end

  def with_stubbed_github(stubs, &block)
    stubs.reduce(block) { |inner, (name, impl)| -> { stub_singleton(Agent::Github, name, impl, &inner) } }.call
  end

  # ---- 3. the reap records all of them ----

  def with_agent_home
    Dir.mktmpdir do |root|
      overrides = { "DEV_AGENT_STATE_DIR" => File.join(root, "state"),
                    "DEV_AGENT_LOG_ROOT" => File.join(root, "logs"),
                    "DEV_AGENT_WORKSPACE_ROOT" => File.join(root, "ai"),
                    "DEV_AGENT_CLAUDE_REPO" => File.join(root, "claude"),
                    "DEV_AGENT_NO_NOTIFY" => "1" }
      original = overrides.keys.to_h { |k| [k, ENV[k]] }
      overrides.each { |k, v| ENV[k] = v }
      begin
        yield root
      ensure
        original.each { |k, v| ENV[k] = v }
      end
    end
  end

  def tick = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: false, verbose: true)

  def ready(number, head) = pr(number: number, head: head, state: "OPEN", draft: false)

  # The whole point: five sixths of a review run used to end up recorded nowhere.
  def test_the_reap_records_every_other_ready_pr_as_an_additional_fix
    recorded = capture_fixes(prs: [ready(36, BRANCH), ready(37, "#{BRANCH}_sig"), ready(38, "#{BRANCH}_pub")],
                             result_url: url(36))
    assert_equal [url(37), url(38)], recorded
  end

  # A draft is unfinished and a closed-unmerged PR shipped nothing. Recording
  # either as a fix would claim work that does not exist.
  def test_a_draft_or_closed_sibling_is_not_recorded_as_a_fix
    recorded = capture_fixes(prs: [ready(36, BRANCH),
                                   pr(number: 37, head: "#{BRANCH}_sig", draft: true),
                                   pr(number: 38, head: "#{BRANCH}_pub", state: "CLOSED")],
                             result_url: url(36))
    assert_empty recorded
  end

  # The session that closed itself out already recorded its own siblings, and
  # POST /fixes dedupes the ROW but still writes the note.
  def test_a_url_the_issue_already_records_is_not_re_recorded
    recorded = capture_fixes(prs: [ready(36, BRANCH), ready(37, "#{BRANCH}_sig")],
                             result_url: url(36), fixes: [{ "url" => url(37) }])
    assert_empty recorded
  end

  # Nothing to append to before an issue has shipped: the endpoint 422s, and the
  # reap must not spend the call to find out.
  def test_nothing_is_recorded_when_the_outcome_is_not_a_fix
    recorded = capture_fixes(prs: [ready(36, BRANCH), ready(37, "#{BRANCH}_sig")],
                             result_url: nil, status: "needs_input")
    assert_empty recorded
  end

  # ---- 4. a sibling that is its OWN issue (ISS-759) ----
  #
  # Recording every sibling on the assigned issue is right when they are one
  # change spread across repos, and wrong when they are several independent
  # changes: those now get their own numbers with `dev issues split`, and each is
  # closed out, deployed and verified where it belongs. Their PRs are still on
  # branches in this run's family — that is what makes them findable at all — so
  # the reap would otherwise record every one of them twice, which is the
  # five-urls-behind-one-number bookkeeping ISS-759 exists to undo.

  def test_a_sibling_titled_for_another_issue_belongs_to_that_issue
    refute Agent::Github.belongs_to_issue?(pr(number: 37, head: "#{BRANCH}_sig", title: "ISS-770: split out"), BRANCH, "651")
    assert Agent::Github.belongs_to_issue?(pr(number: 37, head: "#{BRANCH}_sig", title: "ISS-651: mine"), BRANCH, "651")
    assert Agent::Github.belongs_to_issue?(pr(number: 37, head: "#{BRANCH}_sig", title: "no prefix at all"), BRANCH, "651")
  end

  # Zero-padding is display, not identity: `dev issues` prints ISS-035 and a
  # session types ISS-35.
  def test_the_number_comparison_ignores_zero_padding
    assert Agent::Github.belongs_to_issue?(pr(number: 37, head: "other", title: "ISS-35: mine"), BRANCH, "035")
  end

  # The one asymmetry, and it is deliberate. The branch is assigned by the
  # executor and recorded on the lease; the title is typed by the session. If they
  # ever disagree, the handle that cannot be mistyped wins — the alternative is a
  # delivered fix classified as `nothing_to_do` and, on a producer-filed issue,
  # DISMISSED with its PR sitting ready on GitHub.
  def test_a_pr_on_the_exact_assigned_branch_is_never_disowned_by_its_title
    assert Agent::Github.belongs_to_issue?(pr(number: 36, head: BRANCH, title: "ISS-770: mistitled"), BRANCH, "651")
  end

  # With no number to compare against there is no question to answer, and
  # answering it anyway would drop PRs the branch family legitimately found.
  def test_an_unparseable_issue_number_disowns_nothing
    assert Agent::Github.belongs_to_issue?(pr(number: 37, head: "other", title: "ISS-770: x"), BRANCH, nil)
  end

  def test_prs_in_workspace_drops_a_sibling_that_carries_its_own_number
    primary = pr(number: 36, head: BRANCH)
    split = pr(number: 37, head: "#{BRANCH}_sig", title: "ISS-770: split out")
    Dir.mktmpdir do |ws|
      stubs = { repos_in_workspace: ->(*) { ["mbryzek/lakeviewsummit-ui"] },
                prs_on_branch: ->(*) { [primary] },
                list_prs: ->(*) { [primary, split] } }
      found = with_stubbed_github(stubs) { Agent::Github.prs_in_workspace(ws, BRANCH, "651") }
      assert_equal [36], found.map { |p| p["number"] }
    end
  end

  # The workspace-is-gone fallback: `head:i651_irv` matches siblings loosely, so
  # the same PR arrives by the same route and needs the same answer. There is no
  # exact-branch exemption to make here — search does not return headRefName —
  # and nothing is lost by that: the title half only ever finds this issue's own.
  def test_the_search_fallback_drops_a_sibling_that_carries_its_own_number
    hits = [{ "number" => 36, "url" => url(36), "title" => "ISS-651: mine", "state" => "OPEN" },
            { "number" => 37, "url" => url(37), "title" => "ISS-770: split out", "state" => "OPEN" }]
    found = stub_singleton(Agent::Github, :search, ->(*, **) { hits }) do
      Agent::Github.search_prs(BRANCH, "651")
    end
    assert_equal [36], found.map { |p| p["number"] }
  end

  # Filtered ONCE, at the lookup, and never again at the write: "which PRs are
  # this issue's" has one answer, and the reap's two consumers — classification
  # and the fix list — both read the list `prs_in_workspace`/`search_prs`
  # produced. So there is deliberately no reap-level assertion here; the guard
  # that the reap records everything it is handed is
  # `test_the_reap_records_every_other_ready_pr_as_an_additional_fix` above, and
  # a second copy of this rule in `record_extra_fixes` would be a second thing to
  # keep in step for no handle the lookup does not already have.

  # The contract half, beside the branch rule the sibling naming lives in: a
  # session that reads §1 and stops has to have read which NUMBER each PR carries.
  def test_the_instructions_say_when_a_sibling_needs_its_own_issue_number
    section_one = instructions[/^## 1\. How this ends.*?^## 2\./m]
    refute_nil section_one
    assert_includes section_one, "dev issues split <n> --title"
    assert_match(/Several INDEPENDENT changes\?/, Agent::Prompt.assignment(issue: issue, slug: BRANCH, workspace: "/ws"))
  end

  def url(number) = "https://github.com/mbryzek/lakeviewsummit-ui/pull/#{number}"

  # Drive apply_outcome with the issue still `claimed` and collect the urls it
  # appends. The status write is stubbed out; only the fix calls are the subject.
  def capture_fixes(prs:, result_url:, status: "fixed", fixes: [])
    seen = []
    with_agent_home do
      subject = tick
      result = Agent::Outcome::Result.new(name: "ready_pr", status: status, lease_outcome: "succeeded",
                                          reason: "r", url: result_url)
      record = { "lease_id" => "lse-1", "slug" => BRANCH, "issue" => "651" }
      stubs = {
        Agent::Api => {
          issue: ->(*, **) { { "status" => "claimed", "fixes" => fixes } },
          set_status: ->(*, **) { nil },
          comment: ->(*, **) { nil },
          record_fix: ->(_n, url, **) { seen << url },
        },
        subject => { notify_outcome: ->(*) { nil }, release_lease: ->(*) { nil } },
      }
      pairs = stubs.flat_map { |obj, methods| methods.map { |name, impl| [obj, name, impl] } }
      capture_stdout do
        pairs.reduce(-> { subject.send(:apply_outcome, "651", record, result, nil, prs) }) do |inner, (obj, name, impl)|
          -> { stub_singleton(obj, name, impl, &inner) }
        end.call
      end
    end
    seen
  end
end
