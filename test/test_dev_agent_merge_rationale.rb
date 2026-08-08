#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The rationale the merge lane writes onto its ledger decision (ISS-1080).
#
# `assertions` is what the envelope is evaluated against; the rationale is what a
# HUMAN reads, months later, in the decision feed. Until ISS-1080 it named the
# verifier and stopped there, which left an audit two hops short: back to GitHub
# for the link, and — for a fleet-verified repo, which is most of the lane — on
# from there to whichever runner happened to build the sha. The evidence is
# already on the decision as assertions; these tests are about it also being in
# the sentence that is actually read.
class TestDevAgentMergeRationale < Minitest::Test
  include DevTestSupport

  CANDIDATE = Agent::MergeLane::Candidate.new(
    repo: "mbryzek/playbook-admin", number: 845, title: "ISS-1: a thing",
    url: "https://github.com/mbryzek/playbook-admin/pull/845",
    head_sha: "a" * 40, created_at: "2026-08-08T00:00:00Z",
    verdict: Agent::MergeLane::Verdict.new(code: :mergeable, action: :merge, message: "green"),
    diff_lines: 12, changed_paths: ["src/app.ts"],
  ).freeze

  def rationale(asserts)
    agent_merge_rationale(CANDIDATE, "reversible", { "diff_lines" => 12, "base_sha" => "c" * 40 }.merge(asserts))
  end

  # GitHub Actions: one permanent run page, and that is the whole trail.
  def test_a_run_page_is_named_in_the_rationale
    text = rationale("verified_url" => "https://example.test/run/7")
    assert_includes text, "Evidence: https://example.test/run/7"
  end

  # Fleet verify: no link at all, and a description naming the host and the log
  # file on it. Losing this one is losing the only pointer that exists.
  def test_a_build_log_is_named_in_the_rationale
    text = rationale("verified_detail" => "passed in 0.9m [Mac] /tmp/build.log")
    assert_includes text, "Evidence: passed in 0.9m [Mac] /tmp/build.log"
  end

  # Both, when a producer ever gives both: neither is dropped in favour of the
  # other, because they answer the question differently.
  def test_both_are_named_when_both_exist
    text = rationale("verified_url" => "https://example.test/run/7",
                     "verified_detail" => "passed in 0.9m [Mac] /tmp/build.log")
    assert_includes text, "https://example.test/run/7 — passed in 0.9m [Mac] /tmp/build.log"
  end

  # Silence rather than a sentence hedging about its own evidence. The rationale
  # is required to be true, and "no evidence recorded" beside a merge that a
  # green check justified would read as a weaker claim than the one being made.
  def test_no_evidence_adds_no_sentence
    refute_includes rationale({}), "Evidence"
  end
end
