#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# Util.run_with_timeout exists because of ISS-578: `claude-db start` sat in a
# wedged subprocess for 25+ minutes producing no output, and a run that hangs
# leaves nothing anyone can read afterwards. These tests use real subprocesses —
# the behaviour under test IS process handling, and a stub of it would assert
# nothing.
class TestUtilRunWithTimeout < Minitest::Test
  include DevTestSupport

  def run_cmd(cmd, seconds, **opts)
    Util.run_with_timeout(cmd, :timeout_seconds => seconds, :quiet => true, **opts)
  end

  def test_reports_success_and_failure_distinctly
    _, ok = run_cmd(["true"], 10)
    assert_equal :ok, ok

    _, failed = run_cmd(["false"], 10)
    assert_equal :failed, failed
  end

  def test_capture_returns_stdout
    stdout, outcome = run_cmd(["echo", "hello"], 10, :capture => true)
    assert_equal :ok, outcome
    assert_equal "hello\n", stdout
  end

  def test_without_capture_no_stdout_is_returned
    stdout, outcome = run_cmd(["echo", "hello"], 10)
    assert_equal :ok, outcome
    assert_nil stdout
  end

  # More output than a pipe buffer holds. Reading only after the child exits
  # would deadlock here — the child blocks writing, we block waiting.
  def test_capture_does_not_deadlock_on_output_larger_than_the_pipe_buffer
    stdout, outcome = run_cmd(["sh", "-c", "yes abcdefghij | head -n 200000"], 60, :capture => true)
    assert_equal :ok, outcome
    assert_equal 200_000, stdout.lines.size
  end

  def test_a_command_that_never_exits_times_out
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, outcome = run_cmd(["sleep", "120"], 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal :timed_out, outcome
    assert_operator elapsed, :<, 30, "should have returned at the deadline, not waited out the sleep"
  end

  # THE point of the process group. What hung ISS-578 was `doctl` blocked on a
  # `docker-credential-desktop` child; killing only the pid we spawned leaves
  # that grandchild alive holding the same lock, and the retry hangs identically.
  def test_the_deadline_kills_grandchildren_too
    Dir.mktmpdir("test-pgroup") do |dir|
      marker = File.join(dir, "grandchild-survived")
      # A grandchild that outlives its parent and touches the marker later.
      _, outcome = run_cmd(["sh", "-c", "(sleep 3; touch #{marker}) & sleep 120"], 1)
      assert_equal :timed_out, outcome

      sleep 5
      refute File.exist?(marker),
             "the grandchild outlived the deadline — the kill did not reach the process group"
    end
  end

  # Nobody is at the keyboard in a Claude session or a cron release, so a
  # subprocess that decides to read stdin has to hit EOF rather than block.
  def test_stdin_is_closed_so_a_prompting_subprocess_cannot_block
    stdout, outcome = run_cmd(["cat"], 10, :capture => true)
    assert_equal :ok, outcome
    assert_equal "", stdout
  end

  # An argv array is what makes the pgroup kill and the stdin redirect reliable,
  # and it removes shell quoting from the picture entirely.
  def test_refuses_a_shell_string
    assert_raises(ArgumentError) { run_cmd("echo hello", 10) }
  end

  # Run a block in quiet release mode, yielding the log path and a scratch dir.
  def with_quiet_log
    Dir.mktmpdir("test-quiet-log") do |dir|
      log = File.join(dir, "release.log")
      saved = [ENV[Util::QUIET_ENV], ENV[Util::LOG_FILE_ENV]]
      begin
        Util.quiet!(log)
        yield log, dir
      ensure
        saved[0].nil? ? ENV.delete(Util::QUIET_ENV) : ENV[Util::QUIET_ENV] = saved[0]
        saved[1].nil? ? ENV.delete(Util::LOG_FILE_ENV) : ENV[Util::LOG_FILE_ENV] = saved[1]
      end
    end
  end

  # The reason `capture` exists: RegistryAuth mints a registry credential on
  # stdout, and a release log is not a secret store. Quiet mode sends streamed
  # output to that log, so captured stdout must NOT reach it — while stderr
  # still must, or a failure has nothing to read.
  #
  # The secret is read from a file rather than written into the command, because
  # the ARGV IS ECHOED to the log by design (as Util.run has always done). That
  # is the same shape as the real caller: `doctl registry docker-config` carries
  # no secret in its arguments and emits the credential on stdout.
  def test_quiet_mode_logs_stderr_but_never_captured_stdout
    with_quiet_log do |log, dir|
      secret_file = File.join(dir, "minted")
      File.write(secret_file, "s3cret-registry-token\n")
      stdout, outcome = run_cmd(
        ["sh", "-c", "cat \"$1\"; echo diagnostic 1>&2", "sh", secret_file], 10, :capture => true
      )
      assert_equal :ok, outcome
      assert_equal "s3cret-registry-token\n", stdout

      logged = File.read(log)
      refute_includes logged, "s3cret-registry-token", "captured stdout must never reach the release log"
      assert_includes logged, "diagnostic", "stderr still has to be readable after a failure"
    end
  end

  # The uncaptured half of the same branch — how every release-time call lands.
  # Worth its own test because it is the one spawn redirect keyed by an ARRAY
  # ([:out, :err]) rather than a symbol, so a plain reading of the code does not
  # settle whether Ruby accepts it.
  def test_quiet_mode_sends_streamed_output_to_the_log
    with_quiet_log do |log, _dir|
      stdout, outcome = run_cmd(["sh", "-c", "echo to-stdout; echo to-stderr 1>&2"], 10)
      assert_equal :ok, outcome
      assert_nil stdout

      logged = File.read(log)
      assert_includes logged, "to-stdout"
      assert_includes logged, "to-stderr"
    end
  end
end
