#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev agent run-op` — the command an autonomous session uses to RUN something,
# so that having run it is a fact the executor can read (ISS-815).
#
# Two properties carry the whole design and both are asserted here: everything
# after `--` reaches the operation UNTOUCHED (the wrapper must not eat the
# `--localhost` and `--app` that belong to the operation), and the issue the
# record is filed under comes from the EXECUTOR's environment rather than from
# anything the session chose.
class TestDevAgentRunOp < Minitest::Test
  include DevTestSupport

  def with_session(issue: "815")
    Dir.mktmpdir do |root|
      saved = ENV.slice("DEV_AGENT_ISSUE", "DEV_AGENT_LOG_ROOT")
      ENV["DEV_AGENT_ISSUE"] = issue
      ENV["DEV_AGENT_LOG_ROOT"] = File.join(root, "logs")
      begin
        yield root
      ensure
        %w[DEV_AGENT_ISSUE DEV_AGENT_LOG_ROOT].each { |k| ENV[k] = saved[k] }
      end
    end
  end

  # stdout captured OUTSIDE the exit capture: `run-op` exits with the operation's
  # own status, and an exit raised through capture_stdout would throw away
  # everything the operation said on the way there.
  def run_op(args)
    err = status = nil
    out = capture_stdout { err, status = capture_stderr_and_exit { cmd_agent_run_op(args) } }
    [out.to_s, err, status]
  end

  # The `--` split, which is the difference between running the operation and
  # running a mangled version of it: parse_common_flags would have consumed
  # `--localhost` as the WRAPPER's flag and handed the reconciler a command that
  # silently talked to production instead.
  def test_everything_after_the_separator_reaches_the_operation_untouched
    seen = nil
    with_session do
      stub_shell(->(cmd, opts) { seen = [cmd, opts]; shell_result(output: "done\n") }) do
        run_op(["issues-reconcile", "--", "dev", "issues", "reconcile", "--apply", "--localhost"])
      end
    end
    assert_equal %w[dev issues reconcile --apply --localhost], seen.first
  end

  # The operation is told an ops run is listening; that is what turns its marker
  # line on, and only there (a release log must never see it).
  def test_the_operation_is_told_that_an_ops_run_is_listening
    seen = nil
    with_session do
      stub_shell(->(_cmd, opts) { seen = opts; shell_result }) do
        run_op(["features-reconcile", "--", "dev", "features", "reconcile", "--apply"])
      end
    end
    assert_equal "1", seen[:env][Agent::Ops::LISTENER_ENV]
  end

  # The record carries the operation's OWN exit status and the operation's OWN
  # report — never a summary the session composed — and `run-op` then exits with
  # that same status, so an `&&` chain in a session behaves.
  def test_the_record_is_written_from_what_the_operation_produced
    with_session do
      output = "12 deployed.\n#{Agent::Ops::MARKER} {\"summary\":\"12 deployed.\",\"effects\":{\"deployed\":12}}\n"
      _out, _err, status = stub_shell(->(_cmd, _opts) { shell_result(output: output) }) do
        run_op(["issues-reconcile", "--", "dev", "issues", "reconcile", "--apply"])
      end
      assert_equal 0, status, "run-op exits with the operation's own status, so `&&` chains behave"

      record = Agent::Ops.records(815).first
      assert_equal "issues-reconcile", record.operation
      assert_equal "12 deployed.", record.summary
      assert_equal({ "deployed" => 12 }, record.effects)
      assert_equal 0, record.status
    end
  end

  def test_a_failing_operation_is_recorded_and_its_status_is_propagated
    with_session do
      _out, _err, status = stub_shell(->(_cmd, _opts) { shell_result(output: "boom\n", exitstatus: 4) }) do
        run_op(["issues-reconcile", "--", "dev", "issues", "reconcile", "--apply"])
      end
      assert_equal 4, status
      refute Agent::Ops.succeeded?(Agent::Ops.records(815).first)
    end
  end

  def test_a_timed_out_operation_exits_124_and_is_recorded_as_a_timeout
    with_session do
      _out, _err, status = stub_shell(->(_cmd, _opts) { shell_result(timed_out: true) }) do
        run_op(["api-publish", "--", "api", "publish"])
      end
      assert_equal 124, status
      assert Agent::Ops.records(815).first.timed_out
    end
  end

  # The marker is machinery. The session sees what the operation actually said.
  def test_the_marker_line_is_not_echoed_back_to_the_session
    with_session do
      output = "published 104 applications\n#{Agent::Ops::MARKER} {\"summary\":\"104 published.\"}\n"
      out, = stub_shell(->(_cmd, _opts) { shell_result(output: output) }) do
        run_op(["api-publish", "--", "api", "publish"])
      end
      assert_match(/published 104 applications/, out)
      refute_match(/#{Regexp.escape(Agent::Ops::MARKER)}/, out)
      assert_match(/104 published\./, out, "what it did is still reported, as the record's summary")
    end
  end

  # THE GUARD. The executor names the issue; there is no flag to override it, so
  # a session cannot file a record against work it is not doing — and running
  # this by hand on a laptop writes into nobody's log tree.
  def test_it_refuses_to_run_outside_an_agent_session
    ran = false
    with_session(issue: nil) do
      _out, err, status = stub_shell(->(_cmd, _opts) { ran = true; shell_result }) do
        run_op(["issues-reconcile", "--", "dev", "issues", "reconcile", "--apply"])
      end
      assert_equal 1, status
      assert_match(/DEV_AGENT_ISSUE is not set/, err)
      refute ran, "it must refuse BEFORE running anything"
    end
  end

  def test_it_refuses_a_malformed_invocation_before_running_anything
    ran = false
    [[], ["issues-reconcile"], ["issues-reconcile", "extra", "--", "true"],
     ["../escape", "--", "true"], ["ok", "--timeout", "soon", "--", "true"]].each do |args|
      with_session do
        _out, err, status = stub_shell(->(_cmd, _opts) { ran = true; shell_result }) do
          run_op(args)
        end
        assert_equal 1, status, "#{args.inspect} must be refused"
        assert_match(/agent run-op/, err)
      end
    end
    refute ran, "nothing may execute on a malformed invocation"
  end
end
