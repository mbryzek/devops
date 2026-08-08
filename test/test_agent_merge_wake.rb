#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/dependency_wake'
load File.expand_path('../bin/dev', __dir__)

# The merge lane's fast path onto the dependency-wake sweep (ISS-923).
#
# Agent::DependencyWake (ISS-922) is the backstop: it re-asks every five minutes
# and covers the merges nothing local observes, which is most of them. The lane
# is the exception — it IS the merger — so the answer is knowably different the
# instant `merge!` returns, and a dependent should not sit out the rest of the
# interval for a merge this very process performed.
#
# There is deliberately no second implementation to test here: the whole feature
# is that the merge runs the existing sweep. So what has to hold is the wiring
# and its blast radius — that the merge calls it, that a wake is reported, that
# the cadence mark makes this pass REPLACE the tick's rather than add to it, and
# above all that nothing it does can touch a merge that has already happened.
class TestAgentMergeWake < Minitest::Test
  include DevTestSupport

  Result = Agent::DependencyWake::Result

  def result(woken: [], **rest)
    Result.new(**{ woken: woken, blocked: [], skipped: [], failed: [],
                   dropped: 0, truncated: false }.merge(rest))
  end

  # Runs the post-merge hook with the sweep faked, and reports what it printed
  # and whether the cadence was marked.
  def wake(sweep:)
    marked = false
    out = nil
    stub_singleton(Agent::DependencyWake, :sweep, ->(**) { sweep.call }) do
      stub_singleton(Agent::DependencyWake, :mark_swept, ->(**) { marked = true }) do
        out, = capture_io { agent_merge_wake_deferrals(use_localhost: false) }
      end
    end
    [out, marked]
  end

  def test_a_merge_that_released_a_deferral_says_which
    out, = wake(sweep: -> { result(woken: %w[892 859]) })
    assert_includes out, "ISS-892, ISS-859"
  end

  # The steady state is a fleet with nothing deferred, and a line on every merge
  # saying so is noise on the one output a human reads to see what merged.
  def test_a_merge_that_released_nothing_says_nothing
    out, = wake(sweep: -> { result })
    assert_empty out
  end

  # The cadence is about how often the question is ASKED. Marking here is what
  # makes this pass REPLACE the tick's next one instead of being a second pass
  # thirty seconds later.
  def test_the_pass_marks_the_cadence
    _, marked = wake(sweep: -> { result(woken: %w[892]) })
    assert marked, "an unmarked pass leaves the tick re-asking on its own schedule anyway"
  end

  # The merge has ALREADY HAPPENED by the time this runs. A sweep that raises
  # must not propagate: the deferral it failed to lift expires on its own, and
  # the tick's sweep tries again in five minutes.
  def test_a_sweep_that_raises_leaves_the_merge_alone_and_says_so
    err = nil
    stub_singleton(Agent::DependencyWake, :sweep, ->(**) { raise ApiError, "500 from the platform" }) do
      _, err = capture_io { agent_merge_wake_deferrals(use_localhost: false) }
    end
    assert_includes err, "merged, but the dependency wake did not run"
    assert_includes err, "The next sweep will pick it up"
  end

  # A fast path nothing invokes is the ISS-923 complaint one level up: the
  # feature silently never runs and the fleet just looks quiet.
  def test_the_successful_merge_branch_runs_the_sweep
    source = File.read(File.expand_path("../bin/dev", __dir__))
    merged = source[/def agent_merge_decide_and_merge.*?\n  # `--match-head-commit`/m]
    refute_nil merged, "agent_merge_decide_and_merge no longer has the branch that runs after a merge"
    assert_includes merged, "agent_merge_wake_deferrals(use_localhost",
                    "nothing wakes the issues deferred on this PR — they wait for the next five-minute sweep"
  end
end
