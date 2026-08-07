#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The decision feed is where `dev autonomy workflows KEY` sends you when a
# released loop has had decisions blocked (ISS-756), so the one thing a
# non-approved row is read FOR — why the ledger refused it — has to be in it.
# Without the reason every blocked row looks alike, and the distinction that
# matters (a classification above the reversibility ceiling, which is the ceiling
# working, versus a refusal for any other reason) is invisible.
class TestDevAutonomyDecisions < Minitest::Test
  include DevTestSupport

  def decision(disposition: "blocked", reason: nil, label: "ISS-1: a title")
    { "disposition" => disposition, "status" => "pending",
      "workflow" => { "key" => "pr_auto_merge" },
      "subject" => { "label" => label },
      "disposition_reason" => reason }
  end

  def feed(rows, args)
    capture_stdout do
      path = "/autonomy/decisions?#{args[:query]}"
      with_stubbed_api("GET #{path}" => rows) { cmd_autonomy_decisions(args[:argv]) }
    end
  end

  def test_a_blocked_row_says_why_it_was_refused
    reason = "a decision classified irreversible is beyond the workflow's limit of reversible"
    out = feed([decision(reason: reason)],
               query: "workflow_key=pr_auto_merge&disposition=blocked&limit=25",
               argv: %w[--workflow pr_auto_merge --disposition blocked])
    assert_match(/^blocked\s+pending\s+pr_auto_merge\s+ISS-1: a title$/, out)
    assert_match(/^  ↳ #{Regexp.escape(reason)}$/, out)
  end

  # Auto-approved decisions carry no reason ("Absent when auto-approved"), and an
  # empty trailer under every one of them would bury the rows that do.
  def test_a_row_with_no_reason_gets_no_trailer
    out = feed([decision(disposition: "auto_approved", reason: nil)],
               query: "limit=25", argv: [])
    refute_match(/↳/, out)
    assert_match(/^auto_approved/, out)
  end

  def test_no_matches_says_so
    assert_match(/No decisions match./, feed([], query: "limit=25", argv: []))
  end
end
