#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the fleet-wide arg-error UX pass: bare `dev <command>` names the valid
# subcommands (require_subcommand), and per-command arg errors show that
# command's invocation line inline (usage_exit example:). Only failure paths are
# exercised, which exit before any network/side effect.
class TestDevArgUsage < Minitest::Test
  include DevTestSupport

  # ---- require_subcommand ----

  def test_multi_subcommand_lists_all_options
    out, status = capture_stderr_and_exit { require_subcommand("invariants") }
    assert_equal 1, status
    assert_match(/invariants requires a subcommand \(one of: check, snoozes, snooze, unsnooze\)/, out)
  end

  def test_single_subcommand_names_it_without_one_of
    out, status = capture_stderr_and_exit { require_subcommand("tasks") }
    assert_equal 1, status
    assert_match(/tasks requires a subcommand \(requeue\)/, out)
    refute_match(/one of:/, out)
  end

  def test_every_dispatched_command_has_subcommands
    # Every command wired to require_subcommand must have a non-empty SUBCOMMANDS
    # entry, or the hint would read "()".
    %w[invariants config tasks browserslist docker].each do |cmd|
      refute_nil SUBCOMMANDS[cmd], "SUBCOMMANDS missing #{cmd}"
      refute_empty SUBCOMMANDS[cmd]
    end
  end

  # ---- inline usage examples on arg errors ----

  # Each case invokes a command's real arg-parsing failure path and asserts the
  # relevant invocation line is shown inline. Value is the expected `Usage:`
  # substring.
  def error_cases
    {
      "login unknown arg"         => [-> { cmd_login(["--nope"]) },                    "dev login [--email EMAIL]"],
      "invariants check bad flag" => [-> { cmd_invariants_check(["--bogus"]) },        "dev invariants check"],
      "docker prune bad days"     => [-> { cmd_docker_prune(["--days", "abc"]) },      "dev docker prune"],
      "pending release bad conc"  => [-> { cmd_pending_release(["--concurrency", "0"]) }, "dev pending release"],
      "browserslist stray arg"    => [-> { cmd_browserslist_update(["foo"]) },         "dev browserslist update"],
      "scripts run no name"       => [-> { cmd_scripts_run([]) },                      "dev scripts run <name>"],
    }
  end

  def test_arg_errors_show_inline_usage
    error_cases.each do |label, (callable, expected_usage)|
      out, status = capture_stderr_and_exit { callable.call }
      assert_equal 1, status, "#{label}: expected exit 1"
      assert_match(/  Usage: /, out, "#{label}: missing inline Usage line")
      assert_includes out, expected_usage, "#{label}: wrong/absent invocation line"
      assert_match(/Run `dev help` for usage\./, out, "#{label}: missing help pointer")
    end
  end

  # ---- USAGE stays in sync with the invocation constants ----

  def test_usage_block_contains_each_invocation_line
    [
      LOGIN_INVOCATION, INVARIANTS_CHECK_INVOCATION, SNOOZE_INVOCATION,
      UNSNOOZE_INVOCATION, PENDING_RELEASE_INVOCATION, DOCKER_PRUNE_INVOCATION,
      BROWSERSLIST_INVOCATION, SCRIPTS_RUN_INVOCATION
    ].each do |line|
      assert_includes USAGE, line, "USAGE missing invocation line: #{line}"
    end
  end
end
