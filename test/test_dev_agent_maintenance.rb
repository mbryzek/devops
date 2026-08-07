#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Maintenance — the runner-local housekeeping that replaced the agent-gc,
# aidirs-prune and docker-prune producers (ISS-520).
#
# The bug being guarded against is invisible by construction: a producer's
# fleet-wide daily lock let exactly one machine per day delete ITS OWN logs,
# feature dirs and images, so N-1 runners quietly starved until a disk filled.
# Every assertion below is about a silence — a machine that does not prune, a
# marker that does not advance, a failure nobody counts.
class TestDevAgentMaintenance < Minitest::Test
  include DevTestSupport

  def with_agent_home
    Dir.mktmpdir do |root|
      overrides = {
        "DEV_AGENT_STATE_DIR" => File.join(root, "state"),
        "DEV_AGENT_LOG_ROOT" => File.join(root, "logs"),
        "DEV_AGENT_WORKSPACE_ROOT" => File.join(root, "ai"),
        "DEV_AGENT_DEVOPS_REPO" => File.join(root, "devops"),
      }
      original = overrides.keys.to_h { |k| [k, ENV[k]] }
      overrides.each { |k, v| ENV[k] = v }
      FileUtils.mkdir_p(ENV["DEV_AGENT_WORKSPACE_ROOT"])
      begin
        yield root
      ensure
        original.each { |k, v| ENV[k] = v }
      end
    end
  end

  # Record what the shell chores WOULD have run, without running them.
  # MaintenanceGuard already blocks the real thing; this replaces its no-op with
  # one that remembers, which is how the assertions below see the flags.
  def recording_shell(ok: true)
    ran = []
    stub_singleton(Agent::Maintenance, :run_shell, lambda { |source, trigger|
      ran << Agent::Maintenance.shell_command(source, trigger)
      Agent::Maintenance::Outcome.new(source: source, label: source, ok: ok,
                                      message: ok ? "ok" : "exited 1: boom")
    }) { yield ran }
  end

  # ---- cadence ---------------------------------------------------------------

  # A machine that has never pruned prunes on its first tick. This is the whole
  # rollout story: nothing has to be scheduled, backfilled or triggered for a
  # newly-provisioned (or long-starved) runner to catch up.
  def test_a_machine_that_has_never_run_is_due_immediately
    with_agent_home { assert_equal :first_run, Agent::Maintenance.due(now: Time.now, free_bytes: nil) }
  end

  # The literal value, not the constant: every other cadence assertion here is
  # written in terms of CADENCE_SECONDS and so cannot notice the constant itself
  # moving. A day was the wrong unit (ISS-555) — a runner at max_concurrency can
  # put several GB on disk between two passes, and at 24h the gap between "this
  # machine started filling" and "this machine pruned" was a day of it still
  # claiming work.
  def test_the_routine_path_is_once_an_hour
    assert_equal 3600, Agent::Maintenance::CADENCE_SECONDS
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      write_marker(now - 60)
      assert_nil Agent::Maintenance.due(now: now, free_bytes: nil)
      write_marker(now - Agent::Maintenance::CADENCE_SECONDS - 1)
      assert_equal :cadence, Agent::Maintenance.due(now: now, free_bytes: nil)
    end
  end

  # Cadence is the routine path; the floor is the failure actually being
  # prevented. Since ISS-555 the cooldown and the cadence are both an hour, so
  # what pressure buys is the SHORTENED WINDOWS rather than an earlier run —
  # which makes the assertion below the load-bearing one: when both are due,
  # `due` must return :pressure, because the trigger is what picks the windows.
  def test_disk_pressure_overrides_the_cadence
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      write_marker(now - Agent::Maintenance::PRESSURE_COOLDOWN_SECONDS - 1)
      assert_equal :pressure, Agent::Maintenance.due(now: now, free_bytes: 1)
      assert_equal :cadence, Agent::Maintenance.due(now: now, free_bytes: Agent::Maintenance::PRESSURE_FLOOR_BYTES + 1),
                   "a machine with headroom takes the routine path, and the routine windows with it"
    end
  end

  # Without the cooldown, a machine that is genuinely out of space — still under
  # the floor after a prune that reclaimed everything reclaimable — would run a
  # full `docker prune` every 30 seconds, forever.
  def test_pressure_does_not_become_a_spin_loop
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      write_marker(now - 60)
      assert_nil Agent::Maintenance.due(now: now, free_bytes: 1)
    end
  end

  # ---- retention -------------------------------------------------------------

  def test_the_routine_windows_are_the_ones_the_producers_passed
    with_agent_home do
      recording_shell do |ran|
        Agent::Maintenance.run(trigger: :cadence)
        assert_includes ran.map { |c| c.join(" ") }.join("\n"), "aidirs prune --days 3 --apply"
        assert_includes ran.map { |c| c.join(" ") }.join("\n"), "docker prune --days 7 --apply"
      end
    end
  end

  # ISS-588: the only automatic caller of `claude-db gc` in the fleet passed no
  # `--apply`, and gc has been dry-run-by-default since e87d89e — so nothing on
  # any runner ever reclaimed a session database, and a port was freed only when
  # a human noticed the range was full and ran the command by hand. The flag is
  # the assertion; the rest of this file is about chores that already had it.
  def test_the_session_database_reap_actually_applies
    with_agent_home do
      recording_shell do |ran|
        Agent::Maintenance.run(trigger: :cadence)
        gc = ran.find { |c| c.include?("gc") }
        refute_nil gc, "nothing reclaims session databases, containers or ports without this chore"
        assert_equal [Agent::Paths.claude_db_bin, "gc", "--days", "3", "--apply"], gc
      end
    end
  end

  # The one window that deliberately does NOT shorten under pressure. Everything
  # else these chores delete is reproducible — an image re-pulls, a feature dir
  # re-clones — while a dropped session database is a session's test data, gone.
  # A Postgres container is a couple of hundred MB, so a shorter window buys
  # almost no disk in exchange for reaching further into live work; what a
  # machine short of PORTS needs is this running at all.
  def test_pressure_does_not_shorten_the_session_database_window
    with_agent_home do
      recording_shell do |ran|
        Agent::Maintenance.run(trigger: :pressure)
        gc = ran.find { |c| c.include?("gc") }
        assert_equal Agent::Maintenance::CLAUDE_DB_GC_DAYS.to_s, gc[gc.index("--days") + 1]
      end
    end
  end

  # Both chores shell out to THIS checkout, never to whatever is on PATH: the
  # tick fast-forwards its devops checkout on every Phase A and then runs out of
  # it, so a chore reaching a different copy would run code nothing here updates.
  def test_the_chores_run_this_checkouts_binaries
    with_agent_home do
      recording_shell do |ran|
        Agent::Maintenance.run(trigger: :cadence)
        ran.each do |cmd|
          assert cmd.first.start_with?(Agent::Paths.devops_repo), "#{cmd.first} is not this checkout's"
        end
      end
    end
  end

  # Under pressure everything these two delete is reproducible — an image
  # re-pulls, a feature dir re-clones — so a short window costs a slow rebuild
  # rather than work.
  def test_pressure_shortens_the_windows
    with_agent_home do
      recording_shell do |ran|
        Agent::Maintenance.run(trigger: :pressure)
        flat = ran.map { |c| c.join(" ") }.join("\n")
        assert_includes flat, "aidirs prune --days 1 --apply"
        assert_includes flat, "docker prune --days 1 --apply"
      end
    end
  end

  # The log windows deliberately do NOT shorten. They hold a few MB, so cutting
  # them frees nothing worth having, and what they hold is the post-mortem record
  # for the failure someone is about to investigate.
  def test_pressure_shortens_workspaces_and_leaves_the_post_mortem_window_alone
    assert_equal Agent::Gc::PRESSURE_WORKSPACE_DAYS, Agent::Maintenance.workspace_days(:pressure)
    assert_operator Agent::Gc::PRESSURE_WORKSPACE_DAYS, :<, Agent::Gc::WORKSPACE_DAYS
    assert_equal Agent::Gc::WORKSPACE_DAYS, Agent::Maintenance.workspace_days(:cadence)
    assert_equal 30, Agent::Gc::ROTATED_LOG_DAYS
    assert_equal 30, Agent::Gc::FAILED_ISSUE_DAYS
  end

  # A shortened workspace window must never reach a session that is still
  # running. A job clones its repos in the first minute and then works inside
  # them for hours, so the feature dir's own mtime stops moving while the session
  # is very much alive — and "we were low on disk" is the worst possible reason
  # to delete a running session's working tree.
  def test_a_live_job_workspace_is_never_collected_however_low_the_disk_is
    with_agent_home do
      slug = "i999_abc"
      dir = File.join(Agent::Paths.workspace_root, slug)
      FileUtils.mkdir_p(dir)
      old = Time.now - 30 * 86_400
      File.utime(old, old, dir)

      assert_includes Agent::Gc.plan(workspace_days: Agent::Gc::PRESSURE_WORKSPACE_DAYS).map(&:first), dir

      Agent::Jobs.write("issue" => 999, "pid" => Process.pid, "slug" => slug, "branch" => slug,
                        "started_at" => Time.now.utc.iso8601)
      refute_includes Agent::Gc.plan(workspace_days: Agent::Gc::PRESSURE_WORKSPACE_DAYS).map(&:first), dir,
                      "collected the workspace of a session that is still running"
    end
  end

  # ---- the marker ------------------------------------------------------------

  # Written for EVERY pass, including one where a chore failed. "This machine
  # attempted maintenance" and "maintenance succeeded" are different facts:
  # without the first, a chore that fails every time would re-run every 30
  # seconds, and a failing `docker prune` on a loop is its own outage.
  def test_a_failed_chore_still_advances_the_marker
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      recording_shell(ok: false) do |_ran|
        result = Agent::Maintenance.run(now: now, trigger: :cadence)
        refute result.outcomes.all?(&:ok)
      end
      assert_equal now, Agent::Maintenance.last_run_at
      assert_nil Agent::Maintenance.due(now: now + 60, free_bytes: 1),
                 "a chore that fails every pass must not re-run every tick"
    end
  end

  def test_one_broken_chore_does_not_stop_the_others
    with_agent_home do
      stub_singleton(Agent::Maintenance, :run_shell, lambda { |source, _trigger|
        raise "docker daemon is not running" if source == Agent::Maintenance::DOCKER_SOURCE
        Agent::Maintenance::Outcome.new(source: source, label: source, ok: true, message: "ok")
      }) do
        # A chore that RAISES rather than exiting non-zero must still be one
        # failed chore, not a failed pass: three independent resources, and a
        # dead Docker daemon has nothing to do with collecting logs.
        assert_raises(RuntimeError) { Agent::Maintenance.run(trigger: :cadence) }
      end

      recording_shell(ok: false) do |_ran|
        result = Agent::Maintenance.run(trigger: :cadence)
        assert_equal 1 + Agent::Maintenance::SHELL_SOURCES.length, result.outcomes.length
        assert result.outcomes.find { |o| o.source == Agent::Maintenance::GC_SOURCE }.ok,
               "a failing shell chore must not stop the in-process collection"
      end
    end
  end

  # ---- a chore that never returns (ISS-740) ----------------------------------
  #
  # The chores are where this failure was most likely and least visible. They run
  # in Phase B under the work lock, ahead of reap and claim, and `docker prune`
  # is loudest exactly when the daemon is wedged — it exists to relieve the disk
  # pressure that wedges it. Unbounded, one hung prune stopped the machine
  # claiming anything on every later tick, permanently, with nothing logged,
  # because a hang raises nothing.

  def test_a_chore_that_hangs_is_killed_and_recorded_as_a_failure
    with_agent_home do
      with_real_run_shell(->(*) { shell_result(timed_out: true, timeout: Agent::Maintenance::CHORE_TIMEOUT_SECONDS) }) do
        outcome = Agent::Maintenance.run_shell(Agent::Maintenance::DOCKER_SOURCE, :cadence)
        refute outcome.ok, "a chore that never returned did not succeed"
        assert_match(/timed out after 300s/, outcome.message)
      end
    end
  end

  def test_every_chore_is_given_the_deadline
    with_agent_home do
      seen = []
      with_real_run_shell(lambda { |_cmd, opts|
        seen << opts[:timeout]
        shell_result
      }) do
        Agent::Maintenance::SHELL_SOURCES.each { |source| Agent::Maintenance.run_shell(source, :cadence) }
      end
      assert_equal [Agent::Maintenance::CHORE_TIMEOUT_SECONDS] * 3, seen
    end
  end

  # ENOENT was the only start failure ever caught, and it is only the most
  # LIKELY one: a `bin/dev` or `bin/claude-db` that lost its +x bit raises
  # EACCES, which propagated out of the pass, out of the tick's work phase, and
  # killed the tick every hour. A chore that cannot start is a recorded chore
  # failure like any other — never the reason the machine stops claiming.
  def test_a_chore_binary_that_cannot_be_executed_is_a_failure_not_a_dead_tick
    with_agent_home do
      with_real_run_shell(->(cmd, _opts) { raise Errno::EACCES, cmd.first }) do
        outcome = Agent::Maintenance.run_shell(Agent::Maintenance::AIDIRS_SOURCE, :cadence)
        refute outcome.ok
        assert_match(/could not run/, outcome.message)
      end
    end
  end

  def test_a_missing_chore_binary_is_still_a_failure_not_a_dead_tick
    with_agent_home do
      with_real_run_shell(->(cmd, _opts) { raise Errno::ENOENT, cmd.first }) do
        outcome = Agent::Maintenance.run_shell(Agent::Maintenance::CLAUDE_DB_SOURCE, :cadence)
        refute outcome.ok
        assert_match(/could not run/, outcome.message)
      end
    end
  end

  # `exited 1: ` with nothing after the colon reads like truncated output rather
  # than a command that said nothing.
  def test_a_silent_failure_does_not_report_an_empty_tail
    with_agent_home do
      with_real_run_shell(->(*) { shell_result(exitstatus: 1) }) do
        outcome = Agent::Maintenance.run_shell(Agent::Maintenance::DOCKER_SOURCE, :cadence)
        assert outcome.message.end_with?("exited 1"), "got #{outcome.message.inspect}"
      end
    end
  end

  # ---- what the platform is told ---------------------------------------------

  # The half an error channel structurally cannot cover. Errors report runs that
  # BROKE; they can never report a run that never happened, and from outside the
  # machine "never ran" and "ran clean" are the same silence — which is the exact
  # failure this issue is about.
  def test_the_report_omits_a_timestamp_a_machine_has_never_earned
    with_agent_home do
      stub_singleton(Agent::Maintenance, :disk, ->(*) { [123, 456] }) do
        report = Agent::Maintenance.report
        refute report.key?(:last_maintenance_at),
               "a machine that has never pruned must not report a maintenance time"
        assert_equal 123, report[:disk_free_bytes]
        assert_equal 456, report[:disk_total_bytes]
      end
    end
  end

  def test_the_report_carries_the_last_run_and_what_it_reclaimed
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      free = [10, 42]
      stub_singleton(Agent::Maintenance, :disk, -> { [free.shift || 42, 100] }) do
        recording_shell { |_ran| Agent::Maintenance.run(now: now, trigger: :cadence) }
        report = Agent::Maintenance.report(now: now)
        assert_equal "2026-08-05T12:00:00Z", report[:last_maintenance_at]
        assert_equal 32, report[:maintenance_reclaimed_bytes], "reclaimed is the observed change in free space"
      end
    end
  end

  # A concurrent session writing to disk can eat more than the pass freed. That
  # is a lower bound, not a negative reclaim.
  def test_reclaimed_never_goes_negative
    with_agent_home do
      free = [100, 40]
      stub_singleton(Agent::Maintenance, :disk, -> { [free.shift || 40, 1000] }) do
        recording_shell { |_ran| assert_equal 0, Agent::Maintenance.run(trigger: :cadence).reclaimed_bytes }
      end
    end
  end

  # A machine whose disk cannot be read reports "unknown", never zero: a reported
  # 0 free would trip the pressure path on every tick, and a reported 0 total
  # would look perfectly healthy to the invariant.
  def test_an_unreadable_disk_reports_nothing_rather_than_zero
    with_agent_home do
      stub_singleton(Agent::Maintenance, :disk, ->(*) { nil }) do
        report = Agent::Maintenance.report
        refute report.key?(:disk_free_bytes)
        refute report.key?(:disk_total_bytes)
      end
    end
  end

  # `df -Pk` is POSIX output — one record per filesystem on ONE line. Without -P
  # a long device name wraps and the columns are read off the wrong line, which
  # is how a healthy machine reports a full disk.
  def test_disk_reads_free_and_total_from_df
    with_agent_home do
      out = "Filesystem 1024-blocks      Used Available Capacity Mounted on\n" \
            "/dev/disk3s5  1000000000 400000000 600000000      40% /System/Volumes/Data\n"
      seen = []
      stub_shell(lambda { |cmd, _opts|
        seen.concat(cmd)
        shell_result(output: out)
      }) do
        free, total = Agent::Maintenance.disk
        assert_includes seen, "-Pk", "without POSIX output a long device name wraps onto a second line"
        assert_equal 600_000_000 * 1024, free
        assert_equal 1_000_000_000 * 1024, total
      end
    end
  end

  def write_marker(at)
    Agent::Paths.write_json(Agent::Paths.maintenance_file, { "at" => at.utc.iso8601 }, mode: 0600)
  end
end
