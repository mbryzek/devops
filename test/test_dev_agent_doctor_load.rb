#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev agent doctor`'s load section (ISS-782).
#
# A session cannot distinguish "this machine is oversubscribed" from "my command
# is wedged" — both present as a command that will not finish — and guessing
# wrong is expensive: ISS-780 spent an hour on that ambiguity before proving its
# hang was a real bug rather than starvation, on a runner that sat at load ~50
# the whole time because twenty orphaned spin loops were never reaped.
#
# So the number is STATED. These tests are about the sentence a session reads,
# which is the entire deliverable here — a doctor that computed the right figure
# and printed it in a form nobody acts on would be no better than the silence.
class TestDevAgentDoctorLoad < Minitest::Test
  include DevTestSupport

  def with_load(load, cpus, leaked: [])
    stub_singleton(Agent::Processes, :load_average, -> { load }) do
      stub_singleton(Agent::Processes, :cpu_count, -> { cpus }) do
        stub_singleton(Agent::Processes, :leaked, ->(*_a, **_o) { leaked }) do
          yield capture_stdout { agent_doctor_load }
        end
      end
    end
  end

  def hog(pid)
    Agent::Processes::Entry.new(pid: pid, ppid: 1, pgid: 32_496, command: "zsh",
                                elapsed_seconds: 48_600.0, cpu_seconds: 21_600.0)
  end

  # The divisor is the whole point: 49 is catastrophic on the ten-core Mac minis
  # this runs on and unremarkable on a 64-core box, so a bare load figure is not
  # actionable by a session that does not know the core count.
  def test_reports_load_per_core
    with_load([49.19, 53.83, 52.06], 10) do |out|
      assert_match(/Load: 49\.19 53\.83 52\.06 over 10 cores — 4\.92 per core/, out)
      assert_match(/OVERSUBSCRIBED/, out)
    end
  end

  def test_a_quiet_machine_says_nothing_alarming
    with_load([1.2, 1.4, 1.6], 10) do |out|
      assert_match(/0\.12 per core/, out)
      refute_match(/OVERSUBSCRIBED/, out)
    end
  end

  # The actionable half. Load alone tells a session to wait; load plus "and it is
  # 20 abandoned processes, here is what clears them" tells it what to do.
  def test_names_the_leak_and_how_to_clear_it
    with_load([49.19, 53.83, 52.06], 10, leaked: [(32_683..32_702).map { |pid| hog(pid) }]) do |out|
      assert_match(/20 process\(es\) in 1 abandoned session group\(s\)/, out)
      assert_match(/120\.0 CPU-hour/, out)
      assert_match(/dev agent maintenance/, out)
    end
  end

  # Oversubscribed with nothing leaked is a different diagnosis with a different
  # response — the machine is busy with real work, and there is nothing to reap.
  def test_says_when_the_load_is_live_work
    with_load([49.19, 53.83, 52.06], 10, leaked: []) do |out|
      assert_match(/OVERSUBSCRIBED/, out)
      assert_match(/No abandoned session processes; the load is live work/, out)
      refute_match(/dev agent maintenance/, out)
    end
  end

  # "unknown" rather than a zero. A machine that will not report its load must
  # not be made to look idle — idle is the reading that stops anyone looking.
  def test_unknown_is_reported_as_unknown
    with_load(nil, 10) { |out| assert_match(/Load: unknown/, out) }
    with_load([1.0, 1.0, 1.0], nil) { |out| assert_match(/Load: unknown/, out) }
  end
end
