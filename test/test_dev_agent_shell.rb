#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Shell — the deadline on every subprocess the dispatcher runs (ISS-740).
#
# THE BUG THIS GUARDS IS A HANG, NOT AN ERROR, and that is what made it worth a
# test file of its own: nothing in the suite had ever run a subprocess that does
# not return. `dev agent tick` locks each phase, so a chore that hangs holds that
# lock forever — the machine keeps heartbeating, keeps looking healthy, and never
# claims another issue, with no exception raised and nothing logged. Every
# assertion below is about a command that would still be running.
#
# The three that are not obvious, and each of which is a way a naive wrapper is
# quietly wrong:
#
#   - a command that outlives its deadline is KILLED, and the process is really
#     gone afterwards
#   - a command that writes more than the pipe buffer is NOT strangled by the
#     helper reading only after it waits
#   - a child that leaves a grandchild behind does not outlive the group kill
class TestDevAgentShell < Minitest::Test
  include DevTestSupport

  # A generous ceiling for "this returned rather than hanging". The point of each
  # timing assertion is the difference between seconds and forever, so it is
  # deliberately loose enough not to flake on a loaded runner.
  RETURNED_PROMPTLY = 20

  def elapsed
    started = Time.now
    value = yield
    [value, Time.now - started]
  end

  # ---- the ordinary outcomes ------------------------------------------------

  def test_a_command_that_succeeds_reports_its_output
    result = Agent::Shell.capture("/bin/echo", "hello", timeout: 10)
    assert result.ok?
    refute result.timed_out?
    assert_equal "hello", result.output.strip
    assert_equal 0, result.exitstatus
  end

  def test_a_command_that_fails_is_not_ok_and_keeps_its_exit_status
    result = Agent::Shell.capture("/bin/sh", "-c", "echo boom >&2; exit 3", timeout: 10)
    refute result.ok?
    refute result.timed_out?
    assert_equal 3, result.exitstatus
    assert_includes result.output, "boom"
    assert_equal "exited 3", result.summary
  end

  # `:inherit` is what Toolchain.agent_path parses `$PATH` out of a login shell
  # with. A .zprofile that prints a warning to stderr must not end up spliced
  # into the PATH the whole doctor then scans — which is exactly what merging
  # would do, and it would report a machine missing every tool it has.
  def test_inherited_stderr_is_not_captured_into_stdout
    result = Agent::Shell.capture("/bin/sh", "-c", "echo warning >&2; printf clean", timeout: 10,
                                  stderr: :inherit)
    assert result.ok?
    assert_equal "clean", result.output
  end

  # Every caller distinguishes "not installed" from "ran and failed", so a
  # missing binary must raise rather than come back as a plain failure.
  def test_a_missing_binary_raises_a_system_call_error
    assert_raises(Errno::ENOENT) do
      Agent::Shell.capture("/definitely/not/a/binary", timeout: 10)
    end
  end

  def test_chdir_runs_the_command_where_it_was_told_to
    Dir.mktmpdir do |dir|
      result = Agent::Shell.capture("/bin/pwd", timeout: 10, chdir: dir)
      assert result.ok?
      assert_equal File.realpath(dir), File.realpath(result.output.strip)
    end
  end

  def test_env_reaches_the_child
    result = Agent::Shell.capture("/bin/sh", "-c", 'printf %s "$DEV_SHELL_TEST"', timeout: 10,
                                  env: { "DEV_SHELL_TEST" => "present" })
    assert_equal "present", result.output
  end

  # ---- the hang, which is the whole point -----------------------------------

  def test_a_command_that_outlives_its_deadline_times_out_rather_than_hanging
    result, seconds = elapsed { Agent::Shell.capture("/bin/sleep", "60", timeout: 1) }
    assert result.timed_out?
    refute result.ok?
    assert_nil result.exitstatus, "a killed process has no exit status of its own to report"
    assert_equal "timed out after 1s", result.summary
    assert_operator seconds, :<, RETURNED_PROMPTLY
  end

  # Returning is not enough. A helper that gave up waiting but left the process
  # running would leak one wedged `docker` per tick, forever.
  def test_the_timed_out_process_is_actually_dead
    pidfile = nil
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      result = Agent::Shell.capture("/bin/sh", "-c", "echo $$ > #{pidfile}; sleep 60", timeout: 2)
      assert result.timed_out?
      pid = File.read(pidfile).strip.to_i
      assert_operator pid, :>, 0
      assert reaped?(pid), "pid #{pid} survived the deadline"
    end
  end

  # `dev docker prune` is a Ruby process that shells out to `docker`: killing
  # only the direct child leaves the wedged grandchild running AND holding the
  # output pipe, which is the same hang one level down. The group is what dies.
  def test_a_grandchild_does_not_survive_its_parents_deadline
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "grandchild")
      script = "/bin/sh -c 'echo $$ > #{pidfile}; sleep 60' & sleep 60"
      result, seconds = elapsed { Agent::Shell.capture("/bin/sh", "-c", script, timeout: 2) }
      assert result.timed_out?
      assert_operator seconds, :<, RETURNED_PROMPTLY,
                      "a grandchild holding the pipe open must not hold the helper open"
      pid = File.read(pidfile).strip.to_i
      assert_operator pid, :>, 0
      assert reaped?(pid), "grandchild #{pid} survived the group kill"
    end
  end

  # THE REGRESSION A JOIN-THEN-READ HELPER INTRODUCES. A command writing more
  # than the ~64KB pipe buffer blocks on write until somebody reads; a helper
  # that reads only after `join` would therefore time out and KILL every chatty
  # command. `docker prune --apply` listing each image it removed is exactly
  # that, and the failure would look like a Docker problem rather than a helper
  # bug — it exists to relieve disk pressure, so it is loudest when it matters.
  def test_a_command_that_outruns_the_pipe_buffer_is_not_strangled
    bytes = 512 * 1024
    result, seconds = elapsed do
      Agent::Shell.capture("/bin/sh", "-c", "yes hello | head -c #{bytes}", timeout: 30)
    end
    assert result.ok?, "a chatty command must not be mistaken for a hung one"
    assert_equal bytes, result.output.bytesize
    assert_operator seconds, :<, RETURNED_PROMPTLY
  end

  # A killed command's partial output is usually the whole diagnosis ("Cannot
  # connect to the Docker daemon" and then nothing), so it is kept.
  def test_a_timed_out_command_keeps_what_it_managed_to_say
    result = Agent::Shell.capture("/bin/sh", "-c", "echo cannot connect; sleep 60", timeout: 2)
    assert result.timed_out?
    assert_includes result.output, "cannot connect"
  end

  # ---- the guard ------------------------------------------------------------

  AGENT_LIB = File.expand_path("../lib/agent", __dir__)

  # A timeout that has to be REMEMBERED is a timeout that gets forgotten once and
  # wedges a runner for a week — which is the entire history of this issue: the
  # reasoning was written down in Agent::Checkout in ISS-511 and every module
  # added afterwards shelled out unbounded anyway. So the rule is mechanical
  # rather than cultural: nothing under lib/agent may call Open3 except the one
  # file that puts a deadline on it.
  #
  # Deliberately a scan of the source rather than a note in a comment. If a new
  # call site genuinely needs Open3 directly, this test failing is the
  # conversation about why.
  def test_nothing_under_lib_agent_shells_out_except_agent_shell
    offenders = Dir.glob(File.join(AGENT_LIB, "*.rb")).sort.filter_map do |file|
      next if File.basename(file) == "shell.rb"
      lines = File.readlines(file).each_with_index.select do |line, _i|
        line =~ /\bOpen3\b/ && line !~ /^\s*#/
      end
      next if lines.empty?
      "#{File.basename(file)}:#{lines.map { |_l, i| i + 1 }.join(',')}"
    end
    assert_empty offenders,
                 "these shell out without a deadline — use Agent::Shell.capture(..., timeout:) so a " \
                 "hung binary cannot hold the tick's lock forever (ISS-740): #{offenders.join(' ')}"
  end

  # Every deadline in lib/agent, so the numbers are visible in one place and a
  # new one cannot be added as a bare literal buried in a call. The assertion is
  # about the SHAPE — a named constant, in seconds, bounded — not the values,
  # which are tuned per call site and documented where they are defined.
  def test_every_bounded_call_site_names_its_timeout
    timeouts = {
      Agent::Checkout::PULL_TIMEOUT_SECONDS => "devops self-pull",
      Agent::Checkout::QUERY_TIMEOUT_SECONDS => "local git reads",
      Agent::Toolchain::PROBE_TIMEOUT_SECONDS => "toolchain --version probes",
      Agent::Host::PROBE_TIMEOUT_SECONDS => "registration tool versions",
      Agent::Maintenance::CHORE_TIMEOUT_SECONDS => "one housekeeping chore",
      Agent::Maintenance::DISK_TIMEOUT_SECONDS => "df",
      Agent::Github::TIMEOUT_SECONDS => "one gh read",
      Agent::Notify::TIMEOUT_SECONDS => "one push",
      Agent::Workspace::CLONE_TIMEOUT_SECONDS => "one clone",
      Agent::Tick::CLAUDE_DB_END_TIMEOUT_SECONDS => "claude-db end",
    }
    timeouts.each do |seconds, what|
      assert_kind_of Integer, seconds, "#{what} has no numeric deadline"
      assert_operator seconds, :>, 0, "#{what} has a deadline of #{seconds}s"
      assert_operator seconds, :<=, 600, "#{what} waits #{seconds}s — long enough to look like a hang"
    end
  end

  # A process the OS has reaped, allowing a moment for the kill to land: the
  # signal is delivered asynchronously, so a bare check immediately after the
  # helper returns is a race rather than an assertion.
  def reaped?(pid, within: 5)
    deadline = Time.now + within
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return true
      rescue Errno::EPERM
        return false
      end
      return false if Time.now > deadline
      sleep 0.05
    end
  end
end
