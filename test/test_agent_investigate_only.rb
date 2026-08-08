#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Which sessions may write code.
#
# This used to be answered by issue category alone, and category cannot answer
# it. `infrastructure` is the producer-chore category and covers both
# `weekly-review`, which exists to open PRs, and `product-owner`, which exists
# not to. With only `suggestion` marked investigate-only, the product review had
# to file itself as a member suggestion to get the right prompt — the wrong
# queue, and a wrong answer waiting to happen for the next such producer.
#
# The playbook is the statement of what a session does, so the playbook decides.
class TestAgentInvestigateOnly < Minitest::Test
  include DevTestSupport

  def issue_with(playbook: nil, body: "plain body")
    full = playbook ? "#{body}\n\n#{Agent::Playbook.pointer_line(playbook)}\n" : body
    { "body" => full, "number" => "1" }
  end

  def test_playbook_marks_a_session_investigate_only_whatever_its_category
    assert issue_investigate_only?("improvement", "product-owner")
    assert issue_investigate_only?("infrastructure", "product-owner")
    assert issue_investigate_only?("feature", "product-owner")
  end

  # The regression that motivated this: another producer-filed chore on the same
  # category must still be told to ship a fix.
  def test_weekly_review_still_builds
    refute issue_investigate_only?("infrastructure", "weekly-review")
  end

  # A member's suggestion carries its brief inline and has no playbook pointer,
  # so the category test has to survive.
  def test_suggestion_stays_investigate_only_with_no_playbook
    assert issue_investigate_only?("suggestion", nil)
  end

  def test_ordinary_hand_filed_work_is_unaffected
    refute issue_investigate_only?("improvement", nil)
    refute issue_investigate_only?("bug", nil)
  end

  def test_playbook_key_is_read_from_the_issue_body_pointer
    assert_equal "product-owner", issue_playbook_key(issue_with(playbook: "product-owner"))
  end

  # Human-written issues have no pointer. Returning nil rather than raising is
  # what keeps every hand-filed issue working untouched.
  def test_missing_pointer_is_nil_not_an_error
    assert_nil issue_playbook_key(issue_with)
    assert_nil issue_playbook_key({ "body" => nil })
  end

  # The prompt is the thing that actually changes, so assert on it rather than
  # only on the predicate: an investigate-only session must never be told to
  # open a PR, and must be offered needs_review instead of fixed.
  def test_intro_and_closing_follow_the_playbook
    intro = issue_plan_intro("improvement", "origin.", "product-owner")
    assert_includes intro, "do not open a PR"
    refute_includes intro, "Implement the fix"

    closing = issue_plan_closing("improvement", 42, "product-owner")
    assert_includes closing, "needs_review"
    refute_includes closing, "--status fixed"
  end

  def test_intro_and_closing_unchanged_without_a_playbook
    intro = issue_plan_intro("improvement", "origin.", nil)
    assert_includes intro, "Implement the fix"

    assert_includes issue_plan_closing("improvement", 42, nil), "--status fixed"
  end
end
