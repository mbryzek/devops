#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'yaml'
require_relative 'test_helper'
require 'agent/ci'
require 'agent/errors'
require 'agent/merge_lane'
require 'agent/tick'

# The runner-local half of CI (ISS-763).
#
# What makes this worth testing rather than eyeballing is that every failure here
# is SILENT in the direction that matters. An oversubscribed box does not raise,
# it swaps. A stale cache does not go red, it goes GREEN and the merge lane lands
# it. A preflight that reports an infrastructure fault as exit 1 does not lose
# information anybody can see missing — it just makes a broken runner look like a
# broken branch, and the PR gets read instead of the machine.
#
# So the assertions are about the three properties, one file each way they lie:
# the reservation actually comes out of what the tick claims, the semaphore
# actually excludes, and a fault is actually distinguishable from a test failure.
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

  def provision(slots)
    Agent::Paths.write_json(Agent::Paths.ci_config_file, { "slots" => slots })
  end

  # ---- the reservation ------------------------------------------------------

  def test_a_machine_with_no_ci_config_reserves_nothing
    with_state_dir do
      assert_equal 0, Agent::Ci.reserved
      refute Agent::Ci.enabled?
    end
  end

  def test_slots_are_read_from_the_config
    with_state_dir do
      provision(2)
      assert_equal 2, Agent::Ci.reserved
      assert Agent::Ci.enabled?
    end
  end

  # A hand-edited config must degrade to "no CI here", never to a reservation
  # nobody intended. Reserving garbage would subtract garbage from what the tick
  # claims, and a machine that silently stops claiming looks exactly like a
  # machine with an empty queue.
  def test_a_malformed_slot_count_reserves_nothing
    with_state_dir do
      [nil, "two", -3, "", {}].each do |value|
        Agent::Paths.write_json(Agent::Paths.ci_config_file, { "slots" => value })
        assert_equal 0, Agent::Ci.reserved, "slots: #{value.inspect}"
      end
    end
  end

  # THE POINT OF THE WHOLE RESERVATION: it comes out of the tick's admission
  # control, so the two schedulers on one box add up to the box.
  def test_the_tick_claims_fewer_sessions_by_the_reservation
    with_state_dir do
      t = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: true,
                          now: Time.now, verbose: false)
      runner = { "max_concurrency" => 3 }

      assert_equal 3, t.send(:session_capacity, runner)
      provision(1)
      assert_equal 2, t.send(:session_capacity, runner)
      provision(3)
      assert_equal 0, t.send(:session_capacity, runner), "a CI-only box claims nothing"
    end
  end

  # Zero, not negative: a reservation larger than the machine is a provisioning
  # mistake, and `(max - live).times` on a negative number is a loop that does
  # not run — which is right — but a negative capacity printed in the log line is
  # not something anybody should have to interpret at 3am.
  def test_an_over_large_reservation_floors_at_zero_rather_than_going_negative
    with_state_dir do
      provision(9)
      t = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: true,
                          now: Time.now, verbose: false)
      assert_equal 0, t.send(:session_capacity, { "max_concurrency" => 2 })
    end
  end

  # The reservation has to be NAMED wherever capacity is reported, because the
  # state it produces on a CI-only box — "at capacity (0/0)" — is otherwise
  # indistinguishable from a broken registry read.
  def test_the_capacity_note_names_the_reservation_when_there_is_one
    with_state_dir do
      t = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: true,
                          now: Time.now, verbose: false)
      assert_equal "", t.send(:ci_reservation_note)
      provision(2)
      assert_match(/2 reserved for CI/, t.send(:ci_reservation_note))
    end
  end

  # ---- the slot semaphore ---------------------------------------------------

  # A slot is held by a LIVE PROCESS, so the exclusion has to be proved across
  # processes — a same-process flock re-lock succeeds and would prove nothing.
  def test_a_held_slot_excludes_another_process
    with_state_dir do
      provision(1)
      child = hold_slot_in_child(seconds: 5)
      begin
        wait_until { Agent::Ci.slots_held == 1 }
        assert_equal 1, Agent::Ci.slots_held
        assert_equal :timed_out, Agent::Ci.with_slot(wait_seconds: 1, poll_seconds: 0.1) { :ran },
                     "the only slot was held, so nothing should have run"
      ensure
        reap(child)
      end
    end
  end

  # ...and releases it when the holder dies, with no reaper, no expiry and
  # nothing to clean up: the fd closes and the kernel drops the lock. That is the
  # property that keeps a slot manager off Agent::Tick's "there is no daemon"
  # ledger.
  def test_a_slot_is_free_again_once_its_holder_is_gone
    with_state_dir do
      provision(1)
      child = hold_slot_in_child(seconds: 30)
      wait_until { Agent::Ci.slots_held == 1 }
      Process.kill("KILL", child)
      Process.wait(child)

      wait_until { Agent::Ci.slots_held.zero? }
      assert_equal :ran, Agent::Ci.with_slot(wait_seconds: 5, poll_seconds: 0.1) { :ran }
    end
  end

  def test_a_second_slot_is_available_while_the_first_is_held
    with_state_dir do
      provision(2)
      child = hold_slot_in_child(seconds: 5)
      begin
        wait_until { Agent::Ci.slots_held == 1 }
        assert_equal :ran, Agent::Ci.with_slot(wait_seconds: 1, poll_seconds: 0.1) { :ran }
      ensure
        reap(child)
      end
    end
  end

  def test_with_slot_returns_the_blocks_value_and_yields_the_index
    with_state_dir do
      provision(2)
      assert_equal 0, Agent::Ci.with_slot(wait_seconds: 1) { |index| index }
    end
  end

  # An unprovisioned box running a CI job is a provisioning mistake, and it must
  # say so rather than silently running the build with no admission control at
  # all — which is the oversubscription this whole mechanism exists to prevent.
  def test_with_slot_refuses_on_a_machine_that_reserves_nothing
    with_state_dir do
      error = assert_raises(RuntimeError) { Agent::Ci.with_slot { :ran } }
      assert_match(/not provisioned/, error.message)
    end
  end

  # The deadline is what separates "this box is busy" from "this runner is
  # wedged", so it has to be the deadline asked for rather than the next multiple
  # of the poll interval.
  def test_the_wait_honours_its_deadline_rather_than_the_poll_interval
    with_state_dir do
      provision(1)
      child = hold_slot_in_child(seconds: 10)
      begin
        wait_until { Agent::Ci.slots_held == 1 }
        started = Time.now
        assert_equal :timed_out, Agent::Ci.with_slot(wait_seconds: 1, poll_seconds: 30) { :ran }
        assert_operator Time.now - started, :<, 10, "the poll interval must not extend the deadline"
      ensure
        reap(child)
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
      with_notifications_disabled do
        stub_singleton(Agent::Api, :create_issue, ->(payload, **_opts) { filed << payload }) do
          with_probes(disk: :ok, registry: :fail) do
            2.times { Agent::Ci.preflight(needs: %w[registry]) }
            assert_empty filed, "two faults in a row is not yet an outage"
            Agent::Ci.preflight(needs: %w[registry])
          end
        end
      end

      assert_equal 1, filed.length
      assert_match(/cannot produce a verdict/, filed.first[:title])
      assert_match(/dev ci install --slots 0/, filed.first[:body],
                   "the issue must say how to take the box out of the pool")
      assert_equal "bug", filed.first[:category]
    end
  end

  # ...and it fires ONCE. A streak already past the threshold that re-filed on
  # every job would turn one broken runner into an issue per pull request.
  def test_a_streak_already_escalated_does_not_file_again
    with_state_dir do
      filed = []
      with_notifications_disabled do
        stub_singleton(Agent::Api, :create_issue, ->(payload, **_opts) { filed << payload }) do
          with_probes(disk: :ok, registry: :fail) do
            5.times { Agent::Ci.preflight(needs: %w[registry]) }
          end
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

  # ---- the check contract ---------------------------------------------------

  # THE NAME `ci` IS THE ENROLMENT. Agent::MergeLane finds its one
  # `statusCheckRollup` entry by that literal string, and a repo whose PRs carry
  # no `ci` check merges nothing — deliberately, as the enrolment rule. So a
  # template that renamed the gate job would not fail loudly anywhere: every repo
  # copied from it would simply, silently, stop being mergeable.
  def test_every_workflow_template_names_its_gate_job_ci
    templates.each do |path, doc|
      assert_includes doc.fetch("jobs").keys, Agent::MergeLane::CI_CHECK,
                      "#{path} must define a job named #{Agent::MergeLane::CI_CHECK}"
      gate = doc.fetch("jobs").fetch(Agent::MergeLane::CI_CHECK)
      assert_equal Agent::MergeLane::CI_CHECK, gate["name"],
                   "#{path}: the check name GitHub publishes is the job's `name:`"
    end
  end

  # One check per repo, not one per shard. The gate has to depend on every other
  # job in the file, or a shard added later reports separately and the lane —
  # which reads exactly one entry — never sees it fail.
  def test_the_gate_job_depends_on_every_other_job
    templates.each do |path, doc|
      jobs = doc.fetch("jobs")
      others = jobs.keys - [Agent::MergeLane::CI_CHECK]
      gate = jobs.fetch(Agent::MergeLane::CI_CHECK)
      assert_equal others.sort, Array(gate["needs"]).sort, "#{path}: gate must aggregate every shard"
      assert_equal "always()", gate["if"], "#{path}: a gate that skips on failure reports nothing"
    end
  end

  # The slot semaphore is the ONLY admission control on a box running
  # repository-level runners for several repos at once, and it is opt-in per
  # step: a build shelled directly runs outside it. A template that did that
  # would teach every repo copied from it to oversubscribe the machine.
  def test_every_template_runs_its_build_through_the_slot
    templates.each do |path, doc|
      steps = doc.fetch("jobs").fetch("build").fetch("steps")
      build = steps.find { |s| s["name"] == "build" }
      refute_nil build, "#{path} has no build step"
      assert_match(/dev ci run --/, build.fetch("run"), "#{path}: the build must hold a CI slot")
    end
  end

  def templates
    paths = Dir[File.expand_path("../templates/ci/*.yml", __dir__)]
    refute_empty paths, "no workflow templates found"
    paths.to_h { |path| [File.basename(path), YAML.safe_load_file(path, aliases: true)] }
  end

  # ---- helpers --------------------------------------------------------------

  # Fork a child that takes a slot and holds it. Forked rather than threaded
  # because the exclusion under test is between PROCESSES: flock is per open file
  # description, so a second thread in this process would take the same lock
  # happily and the test would pass while proving nothing.
  def hold_slot_in_child(seconds:)
    fork do
      Agent::Ci.with_slot(wait_seconds: 5, poll_seconds: 0.1) { sleep(seconds) }
      exit!(0)
    end
  end

  def reap(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def with_notifications_disabled
    previous = ENV["DEV_AGENT_NO_NOTIFY"]
    ENV["DEV_AGENT_NO_NOTIFY"] = "1"
    yield
  ensure
    ENV["DEV_AGENT_NO_NOTIFY"] = previous
  end

  def wait_until(timeout: 10)
    deadline = Time.now + timeout
    sleep(0.05) until yield || Time.now > deadline
    raise "condition never became true within #{timeout}s" unless yield
  end

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
