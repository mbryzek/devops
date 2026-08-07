#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/dependency'

# The dispatch gate that asks GitHub instead of the tracker (ISS-649), and the
# hole ISS-739 found in it.
#
# `unshipped` has exactly one job — decide whether the code a blocked issue is
# about to be built on is actually on `main` — and every one of its answers is a
# dispatch decision. A false "shipped" starts a session against code that does
# not exist; a false "unshipped" defers healthy work for a day. The module had no
# test at all, which is how the closed-unmerged case shipped unnoticed.
#
# So the cases here are the whole answer space of one blocker: not shipped by the
# tracker's own reckoning, dismissed, fixed+merged, fixed+open, fixed+closed, and
# every UNKNOWN (`gh` silent, blocker unreadable, no PR fix recorded, a state
# this code does not recognise) — which fail OPEN by policy and must keep doing
# so, since a gate that stalls the queue whenever GitHub is unreachable is a
# worse failure than the one it prevents.
class TestAgentDependency < Minitest::Test
  include DevTestSupport

  URL = "https://github.com/mbryzek/devops/pull/359".freeze
  OTHER_URL = "https://github.com/mbryzek/platform/pull/1600".freeze

  def issue_with_blocker(number: 633, status: "fixed")
    { "number" => "644",
      "links" => [{ "type" => "blocked_by", "direction" => "outgoing",
                    "issue" => { "number" => number, "status" => status } }] }
  end

  def pr(url: URL, state: "OPEN") = { "url" => url, "state" => state, "number" => 359 }

  # Run `unshipped` with the blocker's own record and the PR lookup stubbed.
  # `blocker` nil stands in for an unreadable issue; `prs` maps url => PR (or
  # nil, which is what `gh` returns for every unknown).
  def unshipped(issue, blocker: nil, prs: {})
    stub_singleton(Agent::Api, :issue, lambda { |*, **|
      raise ApiError, "500 from the platform" if blocker == :error
      blocker
    }) do
      stub_singleton(Agent::Github, :pr_by_url, ->(url) { prs[url] }) do
        Agent::Dependency.unshipped(issue, use_localhost: false)
      end
    end
  end

  def fixed_blocker(*urls) = { "fixes" => urls.map { |u| { "url" => u } } }

  # ---- the tracker's own rule, agreed with rather than re-derived ----

  def test_a_blocker_that_is_not_terminal_blocks_on_its_status_alone
    result = unshipped(issue_with_blocker(status: "claimed"))
    assert_equal [{ "number" => 633, "status" => "claimed", "pr" => nil }], result
    assert_equal ["ISS-633 is still `claimed`"], Agent::Dependency.describe(result)
  end

  # Nobody is ever going to ship it, so deferring on it would defer forever.
  def test_a_dismissed_blocker_never_blocks
    assert_empty unshipped(issue_with_blocker(status: "dismissed"))
  end

  def test_an_issue_with_no_blockers_dispatches
    assert_empty unshipped({ "number" => "644", "links" => [] })
    assert_empty unshipped({ "number" => "644" })
  end

  # ---- fixed, with GitHub as the authority ----

  def test_a_merged_fix_dispatches
    assert_empty unshipped(issue_with_blocker,
                           blocker: fixed_blocker(URL), prs: { URL => pr(state: "MERGED") })
  end

  # A reopened issue accumulates fixes: one merged round ago plus one still open
  # is an issue whose code IS on main, and deferring on it would defer a
  # dependent on a PR it never needed.
  def test_any_merged_fix_clears_a_later_open_one
    assert_empty unshipped(issue_with_blocker,
                           blocker: fixed_blocker(URL, OTHER_URL),
                           prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
  end

  def test_an_open_fix_blocks_and_names_the_pr
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr })
    assert_equal 1, result.size
    assert_equal URL, result.first["pr"]["url"]
    assert_equal ["ISS-633 is `fixed`, but its fix #{URL} has not merged"], Agent::Dependency.describe(result)
  end

  # ---- ISS-739: the answer that used to be silently "shipped" ----

  # The whole bug. Marked `fixed`, one recorded fix, and that PR was closed
  # without merging — nothing landed, and the old code answered nil, which the
  # caller reads as "dispatch is safe".
  def test_a_fix_closed_without_merging_still_blocks
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
    assert_equal 1, result.size, "a closed-unmerged fix shipped nothing — that is unshipped, not unknown"
    assert_equal URL, result.first["pr"]["url"]
  end

  # …and says so in words that cannot be read as "not yet". This deferral loop
  # only ends with a human, unlike the open-PR one.
  def test_the_note_distinguishes_closed_from_merely_unmerged
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
    line = Agent::Dependency.describe(result).first
    assert_includes line, "CLOSED WITHOUT MERGING"
    refute_includes line, "has not merged"
  end

  # An open fix outranks a closed one: it is the PR that will actually ship, and
  # naming it is what makes the deferral note actionable.
  def test_an_open_fix_is_named_over_a_closed_one
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "CLOSED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # Among several closed fixes, the LAST RECORDED one — fixes span repos, where
  # PR numbers are not comparable, so the recorded order is the only chronology.
  def test_the_last_recorded_closed_fix_is_the_one_named
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "CLOSED"), OTHER_URL => pr(url: OTHER_URL, state: "CLOSED") })
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # `deployed` and `verified` are past `fixed` on the ladder and get the same
  # treatment: the status is still the tracker's word, not GitHub's.
  def test_the_github_check_covers_every_shipped_status
    %w[fixed deployed verified].each do |status|
      result = unshipped(issue_with_blocker(status: status),
                         blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
      assert_equal 1, result.size, "#{status} must still be checked against GitHub"
    end
  end

  # ---- fail open, everywhere an answer is UNKNOWN ----

  # `gh` missing, unauthenticated, rate-limited, or the url naming no PR. Not
  # knowing is not the same as knowing it did not merge, and a gate that stalls
  # the queue whenever GitHub is unreachable is the worse failure.
  def test_an_unreachable_github_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => nil })
  end

  # One unknown among several is still an unknown: the merged one might be the
  # one that could not be read.
  def test_one_unreadable_pr_among_several_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                           prs: { URL => pr(state: "CLOSED"), OTHER_URL => nil })
  end

  def test_a_blocker_whose_record_cannot_be_read_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: nil)
    assert_empty unshipped(issue_with_blocker, blocker: :error)
  end

  # A fix that is a design document, not a PR: there is no merge to wait for.
  def test_a_non_pr_fix_dispatches
    blocker = { "fixes" => [{ "url" => "https://github.com/mbryzek/claude/blob/main/plans/x.md" }] }
    assert_empty unshipped(issue_with_blocker, blocker: blocker)
    assert_empty unshipped(issue_with_blocker, blocker: { "fixes" => [] })
  end

  # A state this code does not recognise is an unknown too — `closed?` is
  # deliberately not "anything that is not open".
  def test_an_unrecognised_pr_state_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                           prs: { URL => pr(state: "SOMETHING_NEW") })
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: nil) })
  end
end
