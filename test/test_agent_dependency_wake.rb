#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/dependency'
load File.expand_path('../bin/dev', __dir__)

# The other direction of the dependency gate (ISS-923): the deferrals a merge
# releases, the moment it releases them.
#
# `Agent::Tick#defer_for_dependency` puts a blocked issue down for a DAY, because
# what it is waiting on is a human merging a PR and there is nothing cheaper to
# ask. The merge lane is the only merger in this fleet, so at the instant it
# merges, the day is pure latency — ISS-858 sat deferred with platform#2190
# already merged until somebody woke it by hand.
#
# Every case here is a decision about somebody else's snooze, so the axes are:
# does this merge actually release THIS issue (its blocker recorded this url, and
# every OTHER blocker has shipped too), and what happens when a step of it cannot
# be carried out — which must always leave the snooze exactly as it found it and
# let the daily expiry do what it did before this existed.
class TestAgentDependencyWake < Minitest::Test
  include DevTestSupport

  MERGED = "https://github.com/mbryzek/platform/pull/2190".freeze
  OTHER = "https://github.com/mbryzek/devops/pull/359".freeze

  # One `blocked_by` edge, as the server returns it.
  def ref(number, status: "fixed")
    { "type" => "blocked_by", "direction" => "outgoing",
      "issue" => { "number" => number, "status" => status } }
  end

  def dependent(number, *refs) = { "number" => number, "links" => refs }

  def blocker(number, *urls) = { "number" => number, "fixes" => urls.map { |u| { "url" => u } } }

  def pr(url, state) = { "url" => url, "number" => url.split("/").last.to_i, "state" => state }

  # Runs a wake against a stubbed tracker and GitHub, and reports what it DID:
  # the issues it woke, the notes it posted, and the order of the writes.
  #
  # `snoozed` is what the deferred-issue list answers, `issues` is the tracker
  # keyed by number (a missing one stands in for an unreadable record), and `prs`
  # is `gh` (a missing url is `gh` answering nothing at all).
  def wake(snoozed:, issues: {}, prs: { MERGED => nil }, url: MERGED,
           list: nil, wakes: true)
    seen = { woken: [], notes: [], calls: [], asked: [] }
    listing = list || -> { snoozed.map { |n| { "number" => n } } }
    stub_singleton(Agent::Api, :snoozed_issues, ->(**) { listing.call }) do
      stub_singleton(Agent::Api, :issue, ->(number, **) { issues[number] or raise ApiError, "404" }) do
        stub_singleton(Agent::Github, :pr_by_url, ->(u) { seen[:asked] << u; prs[u] }) do
          stub_singleton(Agent::Api, :wake, lambda { |number, **|
            seen[:calls] << :wake
            raise ApiError, "409 from the platform" unless wakes

            seen[:woken] << number
            { "number" => number }
          }) do
            stub_singleton(Agent::Api, :comment, lambda { |number, text, **|
              seen[:calls] << :comment
              seen[:notes] << [number, text]
              { "id" => "cmt-1" }
            }) do
              seen[:result] = Agent::Dependency.wake_dependents(url, use_localhost: false)
            end
          end
        end
      end
    end
    seen
  end

  # The whole point: one deferred issue, one blocker, and that blocker's recorded
  # fix is the PR that just merged.
  def test_a_deferred_dependent_of_the_merged_pr_is_woken
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") })
    assert_equal [644], seen[:result]
    assert_equal [644], seen[:woken]
  end

  # What a human reads on the timeline has to name the merge that released it —
  # and carry the marker, which is what stops the deferrals BEFORE it counting
  # toward DEPENDENCY_DEFER_LIMIT (see test_dev_agent_tick.rb).
  def test_the_note_names_the_merge_and_carries_the_wake_marker
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") })
    number, text = seen[:notes].first
    assert_equal 644, number
    assert_includes text, Agent::Dependency::WAKE_MARKER
    assert_includes text, MERGED
    refute_includes text, "Blocked on a dependency that has not merged",
                    "the note must not read as one more deferral — that string IS the attempt count"
  end

  # THE WAKE FIRST. A note without a wake would restart the attempt count on an
  # issue still sitting out of the queue, which is the silent aging the limit
  # exists to catch; a wake without a note only costs the count.
  def test_the_snooze_is_cleared_before_the_note_is_written
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") })
    assert_equal %i[wake comment], seen[:calls]
  end

  # An issue can be blocked on several things. Waking on the first merge would
  # hand a session code it still cannot branch from — the claim would re-defer it,
  # which is a wasted lease and a deferral this feature caused.
  def test_a_second_blocker_that_has_not_merged_keeps_the_issue_deferred
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633), ref(700)),
                          633 => blocker(633, MERGED), 700 => blocker(700, OTHER) },
                prs: { MERGED => pr(MERGED, "MERGED"), OTHER => pr(OTHER, "OPEN") })
    assert_empty seen[:result]
    assert_empty seen[:calls], "the snooze must be left exactly as it was found"
  end

  def test_every_blocker_shipped_wakes_the_issue
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633), ref(700)),
                          633 => blocker(633, MERGED), 700 => blocker(700, OTHER) },
                prs: { MERGED => pr(MERGED, "MERGED"), OTHER => pr(OTHER, "MERGED") })
    assert_equal [644], seen[:result]
  end

  # Most deferred issues have nothing to do with the PR in hand, and a deferral
  # is not always a dependency one — `dev issues snooze --days` parks work for
  # every other reason too.
  def test_a_deferral_that_does_not_name_this_pr_is_left_alone
    seen = wake(snoozed: [644, 645],
                issues: { 644 => dependent(644, ref(700)), 700 => blocker(700, OTHER),
                          645 => { "number" => 645 } },
                prs: { OTHER => pr(OTHER, "OPEN") })
    assert_empty seen[:result]
    assert_empty seen[:calls]
  end

  # Several issues waiting on one PR all wake, and the blocker is read ONCE:
  # several dependents of one blocker is the normal shape of a fan-out.
  def test_every_dependent_of_one_blocker_wakes_on_a_single_read
    reads = []
    seen = nil
    merged = pr(MERGED, "MERGED")
    stub_singleton(Agent::Api, :snoozed_issues, ->(**) { [{ "number" => 644 }, { "number" => 645 }] }) do
      issues = { 644 => dependent(644, ref(633)), 645 => dependent(645, ref(633)), 633 => blocker(633, MERGED) }
      stub_singleton(Agent::Api, :issue, ->(n, **) { reads << n; issues[n] }) do
        stub_singleton(Agent::Github, :pr_by_url, ->(_u) { merged }) do
          stub_singleton(Agent::Api, :wake, ->(n, **) { { "number" => n } }) do
            stub_singleton(Agent::Api, :comment, ->(*, **) { {} }) do
              seen = Agent::Dependency.wake_dependents(MERGED, use_localhost: false)
            end
          end
        end
      end
    end
    assert_equal [644, 645], seen
    assert_equal 1, reads.count(633), "the blocker's fixes are read once for the whole walk"
  end

  # A fix url is recorded by hand and a PR url has suffixes (`/files`, a review
  # anchor), so the two are compared as the PR they name.
  def test_a_fix_url_with_a_suffix_still_matches_the_merged_pr
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, "#{MERGED}/files") },
                prs: { "#{MERGED}/files" => pr(MERGED, "MERGED") })
    assert_equal [644], seen[:result]
  end

  # ---- fail open: an unknown leaves the snooze alone ----

  # Nothing merged that anybody could be waiting on, and nothing is read at all.
  def test_a_fix_that_is_not_a_pull_request_reads_nothing
    stub_singleton(Agent::Api, :snoozed_issues, ->(**) { flunk "nothing to look up" }) do
      assert_empty Agent::Dependency.wake_dependents("https://docs.google.com/document/d/1",
                                                     use_localhost: false)
      assert_empty Agent::Dependency.wake_dependents(nil, use_localhost: false)
    end
  end

  # The deferred-issue list is one API call, and a merge that cannot make it is
  # still a merge. The daily expiry is what this falls back to.
  def test_a_tracker_that_cannot_be_listed_wakes_nothing_and_raises_nothing
    seen = wake(snoozed: [], list: -> { raise ApiError, "500 from the platform" })
    assert_empty seen[:result]
  end

  def test_an_unreadable_deferred_issue_is_skipped_rather_than_woken
    seen = wake(snoozed: [644, 645],
                issues: { 645 => dependent(645, ref(633)), 633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") })
    assert_equal [645], seen[:result], "644 could not be read — its snooze is not ours to touch"
  end

  # `gh` silent is an unknown, and an unknown is not a merge. This is where the
  # fail-open runs the OPPOSITE way from the gate: there, an unreadable PR
  # dispatches, because refusing would stall the queue; here it leaves the
  # deferral alone, because the deferral already expires on its own. Read through
  # `unshipped`, an outage would wake every deferral a merge touched and burn a
  # lease apiece re-deferring them.
  def test_a_second_blocker_github_cannot_answer_for_leaves_the_deferral_alone
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633), ref(700)),
                          633 => blocker(633, MERGED), 700 => blocker(700, OTHER) },
                prs: { MERGED => pr(MERGED, "MERGED"), OTHER => nil })
    assert_empty seen[:result]
    assert_empty seen[:calls]
  end

  # A blocker whose only fix is a design document has no merge to observe, so
  # whether its code is on main is not a question this can answer.
  def test_a_second_blocker_fixed_by_a_document_leaves_the_deferral_alone
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633), ref(700)),
                          633 => blocker(633, MERGED),
                          700 => blocker(700, "https://docs.google.com/document/d/1") },
                prs: { MERGED => pr(MERGED, "MERGED") })
    assert_empty seen[:result]
  end

  # The merged url itself needs NO `gh` call — the lane merged it a moment ago,
  # and GitHub's own API lags its merges by seconds.
  def test_the_just_merged_pr_is_taken_as_merged_without_asking_github
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) },
                prs: {})
    assert_equal [644], seen[:result]
    assert_empty seen[:asked], "the lane merged it a moment ago — there is nothing to ask"
  end

  # A blocker nobody is ever going to ship never held anything back, so it does
  # not hold up a wake either.
  def test_a_dismissed_second_blocker_does_not_hold_up_the_wake
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633), ref(700, status: "dismissed")),
                          633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") })
    assert_equal [644], seen[:result]
  end

  # A snooze that will not clear is NOT woken — and above all gets no note, which
  # would otherwise restart the attempt count on an issue still out of the queue.
  def test_a_snooze_that_will_not_clear_is_not_reported_and_gets_no_note
    seen = wake(snoozed: [644],
                issues: { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) },
                prs: { MERGED => pr(MERGED, "MERGED") }, wakes: false)
    assert_empty seen[:result]
    assert_empty seen[:notes]
    assert_equal [:wake], seen[:calls]
  end

  # The reverse half-failure: the issue IS back in the queue, so it is reported as
  # woken. Losing the marker only means a still-blocked issue reaches a human one
  # deferral sooner, which is the safe side of that trade.
  def test_a_note_that_will_not_post_still_counts_as_woken
    seen = nil
    issues = { 644 => dependent(644, ref(633)), 633 => blocker(633, MERGED) }
    merged = pr(MERGED, "MERGED")
    stub_singleton(Agent::Api, :snoozed_issues, ->(**) { [{ "number" => 644 }] }) do
      stub_singleton(Agent::Api, :issue, ->(n, **) { issues[n] }) do
        stub_singleton(Agent::Github, :pr_by_url, ->(_u) { merged }) do
          stub_singleton(Agent::Api, :wake, ->(n, **) { { "number" => n } }) do
            stub_singleton(Agent::Api, :comment, ->(*, **) { raise ApiError, "500" }) do
              seen = Agent::Dependency.wake_dependents(MERGED, use_localhost: false)
            end
          end
        end
      end
    end
    assert_equal [644], seen
  end

  # ---- the wiring: the merge is what calls this ----
  #
  # A wake nothing invokes is a feature that silently never runs, which is the
  # ISS-923 complaint itself one level up.

  def test_the_successful_merge_branch_wakes_the_dependents
    source = File.read(File.expand_path("../bin/dev", __dir__))
    merged = source[/def agent_merge_decide_and_merge.*?\n  # `--match-head-commit`/m]
    refute_nil merged, "agent_merge_decide_and_merge no longer has the branch that runs after a merge"
    assert_includes merged, "agent_merge_wake_dependents(candidate",
                    "nothing wakes the issues deferred on this PR — they wait out the rest of their day"
  end

  def test_the_merge_reports_what_it_woke_and_says_nothing_when_it_woke_nothing
    candidate = Struct.new(:url).new(MERGED)
    stub_singleton(Agent::Dependency, :wake_dependents, ->(*, **) { [644, 645] }) do
      out, = capture_io { agent_merge_wake_dependents(candidate, use_localhost: false) }
      assert_includes out, "ISS-644, ISS-645"
    end
    stub_singleton(Agent::Dependency, :wake_dependents, ->(*, **) { [] }) do
      out, = capture_io { agent_merge_wake_dependents(candidate, use_localhost: false) }
      assert_empty out, "a merge that released nothing has nothing to say about it"
    end
  end
end
