#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/ci'
require 'agent/errors'
require 'agent/merge_lane'
require 'agent/tick'

# The machine-side half of CI: is this runner fit to produce a verdict, and may
# it trust what it has cached. The JOB that uses both is Agent::Verify — see
# test_agent_verify.rb.
#
# What makes this worth testing rather than eyeballing is that every failure here
# is SILENT in the direction that matters. A stale cache does not go red, it goes
# GREEN and the merge lane lands it. A preflight that reports an infrastructure
# fault as exit 1 does not lose information anybody can see missing — it just
# makes a broken runner look like a broken branch, and the PR gets read instead
# of the machine.
#
# The slot and reservation assertions that used to live here are gone with the
# thing they tested (ISS-848). They existed because GitHub Actions was a second
# scheduler on this hardware; there is one scheduler now, and what replaced the
# arithmetic is an ORDERING, asserted in test_agent_verify.rb.
class TestAgentCi < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |root|
      previous = ENV["DEV_AGENT_STATE_DIR"]
      begin
        ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
        FileUtils.mkdir_p(ENV["DEV_AGENT_STATE_DIR"])
        yield root
      ensure
        ENV["DEV_AGENT_STATE_DIR"] = previous
      end
    end
  end

  # ---- the false-green rule -------------------------------------------------

  # Warmth is an allowlist of exactly one event. Everything else builds cold,
  # including events nobody has thought of yet — the one failure mode here has no
  # human downstream, so the default cannot be "trust the cache".
  def test_only_a_pull_request_reuses_incremental_state
    refute Agent::Ci.clean_build?(event: "pull_request")
    %w[push schedule workflow_dispatch merge_group release].each do |event|
      assert Agent::Ci.clean_build?(event: event), "#{event} must build clean"
    end
    assert Agent::Ci.clean_build?(event: nil)
    assert Agent::Ci.clean_build?(event: "")
  end

  # ---- preflight ------------------------------------------------------------

  # A repo whose build never starts Docker is not held to a Docker daemon. The
  # probes are opt-in so a Ruby suite's CI does not go red for a dependency it
  # does not have.
  def test_only_the_requested_probes_run
    with_state_dir do
      with_probes(disk: :ok) do
        assert_equal %w[disk], Agent::Ci.preflight.checks.map(&:name)
      end
      with_probes(disk: :ok, docker: :ok, registry: :ok, database: :ok) do
        assert_equal %w[disk docker registry database],
                     Agent::Ci.preflight(needs: %w[docker registry database]).checks.map(&:name)
      end
    end
  end

  # An unrecognised need is ignored rather than fatal: a workflow naming a probe
  # a newer `dev` will have should run on today's runner, not fail closed on its
  # own configuration.
  def test_an_unknown_need_is_ignored
    with_state_dir do
      with_probes(disk: :ok) do
        assert Agent::Ci.preflight(needs: %w[quantum]).ok?
      end
    end
  end

  # ---- the heap declaration (ISS-1123) --------------------------------------
  #
  # THE BACKSTOP, not a second scheduler. Agent::Verify already refuses to CLAIM
  # a job this box cannot give the heap for, so in the ordinary case this never
  # fires. It exists for the two cases the claim-time match cannot cover: a
  # hand-run `dev ci verify` on the small box — which is exactly how a repo's
  # first build is confirmed — and a tick whose registry read failed, leaving the
  # derived heap at the floor.
  #
  # What it buys there is the whole issue: the failure renders as an
  # INFRASTRUCTURE FAULT (exit 75, "fix the machine") instead of as an OOM the
  # merge lane reads as a red suite and a human investigates.
  def test_a_build_declaring_more_heap_than_this_box_gives_is_an_infrastructure_fault
    with_state_dir do
      with_probes(disk: :ok) do
        stub_singleton(Agent::Heap, :gigabytes_here, -> { 4 }) do
          report = Agent::Ci.preflight(needs: ["heap:12G"])
          refute report.ok?
          assert_equal %w[heap], report.faults.map(&:name)
          assert_match(/gives 4G, the build declares heap:12G/, report.summary)
        end
      end
    end
  end

  def test_a_declaration_this_box_satisfies_passes
    with_state_dir do
      with_probes(disk: :ok) do
        stub_singleton(Agent::Heap, :gigabytes_here, -> { 24 }) do
          assert Agent::Ci.preflight(needs: ["heap:12G"]).ok?
        end
      end
    end
  end

  # No declaration, no check — which is every npm and Elm build, and was every
  # repo in the fleet before this.
  def test_a_build_that_declares_no_heap_is_not_checked_for_one
    with_state_dir do
      with_probes(disk: :ok) do
        assert_equal %w[disk], Agent::Ci.preflight(needs: %w[quantum]).checks.map(&:name)
      end
    end
  end

  # THE ONE EXCEPTION TO "an unknown need is ignored", and the reason it has to
  # be one: under that rule a misspelt heap token reads as no minimum, the job
  # runs on a box too small for it and OOMs — silently reintroducing the exact
  # failure the declaration exists to prevent.
  def test_a_malformed_heap_token_is_a_fault_rather_than_an_ignored_name
    with_state_dir do
      with_probes(disk: :ok) do
        report = Agent::Ci.preflight(needs: ["heap=12G"])
        refute report.ok?
        assert_equal %w[heap], report.faults.map(&:name)
        assert_match(/does not parse/, report.summary)
      end
    end
  end

  def test_a_failing_probe_makes_the_report_a_fault_and_names_the_remedy
    with_state_dir do
      with_probes(disk: :ok, registry: :fail) do
        report = Agent::Ci.preflight(needs: %w[registry])
        refute report.ok?
        assert_equal %w[registry], report.faults.map(&:name)
        assert_match(/doctl cannot authenticate/, report.summary)
        assert_equal "doctl auth init", report.faults.first.remedy
      end
    end
  end

  # `doctl` absent and `doctl` broken are the same fact here — this runner cannot
  # mint a registry credential — and neither may escape as an exception, which
  # would surface as a crashed step rather than a reported fault.
  def test_a_missing_binary_is_a_fault_not_an_exception
    with_state_dir do
      stub_shell(->(cmd, _opts) { raise Errno::ENOENT, cmd.first }) do
        report = Agent::Ci.preflight(needs: %w[docker])
        refute report.ok?
        assert_includes report.summary, "docker"
      end
    end
  end

  def test_disk_below_the_floor_is_a_fault
    with_state_dir do
      # `df -k` reports 1K blocks; column 4 is what is available.
      stub_shell(lambda { |cmd, _opts|
        assert_equal "df", cmd.first
        shell_result(output: "Filesystem 1024-blocks Used Available Capacity\n/dev/disk1 100 90 1000000 99%\n")
      }) do
        report = Agent::Ci.preflight
        refute report.ok?
        assert_match(/floor is/, report.faults.first.detail)
      end
    end
  end

  def test_unreadable_free_space_is_a_fault_rather_than_an_assumed_pass
    with_state_dir do
      stub_shell(->(_cmd, _opts) { shell_result(output: "", exitstatus: 1) }) do
        refute Agent::Ci.preflight.ok?
      end
    end
  end

  # ---- escalation -----------------------------------------------------------

  # A red CI job is read by whoever opened the PR. A BROKEN RUNNER is read by
  # nobody — which is the whole of failure mode 2 — so the fault is recorded on
  # the machine as well as reported to the job, on the streak the fleet already
  # escalates from.
  def test_a_fault_is_recorded_on_the_machine_for_escalation
    with_state_dir do
      with_probes(disk: :ok, registry: :fail) do
        Agent::Ci.preflight(needs: %w[registry])
      end
      assert_equal 1, Agent::Errors.count(Agent::Ci::ERROR_SOURCE)
      assert_match(/registry/, Agent::Errors.list.first["message"])
    end
  end

  # ...and a clean pass CLEARS it, which is what makes the streak mean "in a row"
  # rather than "ever". Without this a machine that failed twice in March would
  # escalate on its next single failure in August.
  def test_a_clean_preflight_clears_the_streak
    with_state_dir do
      with_probes(disk: :ok, registry: :fail) { Agent::Ci.preflight(needs: %w[registry]) }
      assert_equal 1, Agent::Errors.count(Agent::Ci::ERROR_SOURCE)
      with_probes(disk: :ok, registry: :ok) { Agent::Ci.preflight(needs: %w[registry]) }
      assert_equal 0, Agent::Errors.count(Agent::Ci::ERROR_SOURCE)
    end
  end

  # THE ESCALATION ITSELF. Three faults in a row on one runner files an issue,
  # through the same Agent::Escalation the tick's own chores use — because
  # nothing else will ever tell anybody that this box has stopped being able to
  # answer. Two faults must not file: a single bad pull is not an outage.
  def test_three_consecutive_faults_file_an_issue_naming_the_machine
    with_state_dir do
      filed = []
      stub_singleton(Agent::Api, :create_issue, ->(payload, **_opts) { filed << payload }) do
        with_probes(disk: :ok, registry: :fail) do
          2.times { Agent::Ci.preflight(needs: %w[registry]) }
          assert_empty filed, "two faults in a row is not yet an outage"
          Agent::Ci.preflight(needs: %w[registry])
        end
      end

      assert_equal 1, filed.length
      assert_match(/cannot produce a verdict/, filed.first[:title])
      assert_match(/dev agent pause/, filed.first[:body],
                   "the issue must say how to take the box out of the pool, with a command that exists")
      assert_equal "bug", filed.first[:category]
    end
  end

  # ...and it fires ONCE. A streak already past the threshold that re-filed on
  # every job would turn one broken runner into an issue per pull request.
  def test_a_streak_already_escalated_does_not_file_again
    with_state_dir do
      filed = []
      stub_singleton(Agent::Api, :create_issue, ->(payload, **_opts) { filed << payload }) do
        with_probes(disk: :ok, registry: :fail) do
          5.times { Agent::Ci.preflight(needs: %w[registry]) }
        end
      end
      assert_equal 1, filed.length
    end
  end

  # Recording is decoration on a report that has already been computed. A state
  # dir it cannot write must not turn a preflight PASS into a crashed step, which
  # would fail the branch for a reason unrelated to anything checked.
  def test_a_failed_recording_does_not_break_the_report
    with_state_dir do
      stub_singleton(Agent::Errors, :clear, ->(_source) { raise Errno::EACCES }) do
        with_probes(disk: :ok) { assert Agent::Ci.preflight.ok? }
      end
    end
  end

  # ---- helpers --------------------------------------------------------------

  # Every probe shells out through Agent::Shell.capture, so one stub covers all
  # of them; the command's first token says which probe is asking.
  PROBE_BINARIES = { "df" => :disk, "docker" => :docker, "doctl" => :registry }.freeze

  def with_probes(outcomes, &block)
    stub_shell(lambda { |cmd, _opts|
      probe = PROBE_BINARIES[File.basename(cmd.first)] || :database
      case outcomes.fetch(probe, :ok)
      when :ok   then shell_result(output: probe_output(probe))
      when :fail then shell_result(output: "boom", exitstatus: 1)
      end
    }, &block)
  end

  def probe_output(probe)
    case probe
    when :disk     then "Filesystem 1024-blocks Used Available Capacity\n/dev/disk1 100 1 999999999 1%\n"
    when :docker   then "27.0.0"
    when :registry then "active"
    else "5433"
    end
  end
end
