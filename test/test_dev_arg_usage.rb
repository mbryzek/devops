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
    out, status = capture_stderr_and_exit { require_subcommand("config") }
    assert_equal 1, status
    assert_match(/config requires a subcommand \(one of: check, rollout\)/, out)
  end

  def test_single_subcommand_names_it_without_one_of
    out, status = capture_stderr_and_exit { require_subcommand("docker") }
    assert_equal 1, status
    assert_match(/docker requires a subcommand \(prune\)/, out)
    refute_match(/one of:/, out)
  end

  def test_tasks_lists_both_subcommands
    out, status = capture_stderr_and_exit { require_subcommand("tasks") }
    assert_equal 1, status
    assert_match(/tasks requires a subcommand \(one of: requeue, delete\)/, out)
  end

  def test_every_dispatched_command_has_subcommands
    # Every command wired to require_subcommand must have a non-empty SUBCOMMANDS
    # entry, or the hint would read "()".
    %w[config tasks browserslist docker aidirs prune issues agent].each do |cmd|
      refute_nil SUBCOMMANDS[cmd], "SUBCOMMANDS missing #{cmd}"
      refute_empty SUBCOMMANDS[cmd]
    end
  end

  # ---- resolve_subcommand (default-on-nil/flag dispatch heuristic) ----

  def test_resolve_subcommand_defaults_when_absent
    argv = []
    assert_equal "check", resolve_subcommand(argv, default: "check")
    assert_empty argv
  end

  def test_resolve_subcommand_defaults_when_leading_flag
    # A leading flag belongs to the default subcommand's args, not a subcommand.
    argv = ["--app", "acumen"]
    assert_equal "check", resolve_subcommand(argv, default: "check")
    assert_equal ["--app", "acumen"], argv, "flag must be left for the handler"
  end

  def test_resolve_subcommand_shifts_named_subcommand
    argv = ["release", "--concurrency", "2"]
    assert_equal "release", resolve_subcommand(argv, default: "check")
    assert_equal ["--concurrency", "2"], argv, "named subcommand must be consumed"
  end

  def test_resolve_subcommand_returns_unknown_token_asis
    argv = ["bogus"]
    assert_equal "bogus", resolve_subcommand(argv, default: "check")
    assert_empty argv
  end

  # ---- inline usage examples on arg errors ----

  # Each case invokes a command's real arg-parsing failure path and asserts the
  # relevant invocation line is shown inline. Value is the expected `Usage:`
  # substring.
  def error_cases
    {
      "auth login unknown arg"    => [-> { cmd_auth_login(["--nope"]) },               "dev auth login [--email EMAIL]"],
      "auth ai set no token"      => [-> { cmd_auth_ai_set([]) },                      "dev auth ai set <token>"],
      "auth status stray flag"    => [-> { cmd_auth_status(["--nope"]) },              "dev auth [status]"],
      "invariants check bad flag" => [-> { cmd_invariants_check(["--bogus"]) },        "dev invariants [check]"],
      "docker prune bad days"     => [-> { cmd_docker_prune(["--days", "abc"]) },      "dev docker prune"],
      "deploy all bad conc"       => [-> { cmd_deploy_all(["--concurrency", "0"]) }, "dev deploy all"],
      "browserslist stray arg"    => [-> { cmd_browserslist_update(["foo"]) },         "dev browserslist update"],
      "scripts run no name"       => [-> { cmd_scripts_run([]) },                      "dev scripts run <name>"],
      "agent tick stray arg"      => [-> { cmd_agent_tick(["--nope"]) },               "dev agent tick [--dry-run]"],
      "agent logs no issue"       => [-> { cmd_agent_logs([]) },                       "dev agent logs <issue>"],
      "agent runs bad limit"      => [-> { cmd_agent_runs(["--limit", "0"]) },         "dev agent runs"],
      "agent playbooks stray arg" => [-> { cmd_agent_playbooks(["--nope"]) },          "dev agent playbooks"],
      "agent playbook no key"     => [-> { cmd_agent_playbook([]) },                   "dev agent playbook <key>"],
      "agent refresh no issue"    => [-> { cmd_agent_refresh([]) },                    "dev agent refresh <issue>"],
      "agent release no issue"    => [-> { cmd_agent_release([]) },                    "dev agent release <issue>"],
      "agent gc stray arg"        => [-> { cmd_agent_gc(["--nope"]) },                 "dev agent gc"],
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

  # ---- reject_unknown_args (common-flags-only commands) ----

  def test_reject_unknown_args_errors_with_inline_usage
    out, status = capture_stderr_and_exit { reject_unknown_args("tasks requeue", ["--typo"]) }
    assert_equal 1, status
    assert_match(/tasks requeue: unknown argument: --typo/, out)
    assert_match(%r{  Usage: dev tasks requeue}, out)
  end

  def test_reject_unknown_args_pluralizes_and_is_noop_when_empty
    out, _ = capture_stderr_and_exit { reject_unknown_args("config check", %w[a b]) }
    assert_match(/unknown arguments: a, b/, out)

    quiet, status = capture_stderr_and_exit { reject_unknown_args("config check", []) }
    assert_nil status
    assert_empty quiet
  end

  def test_common_flag_only_commands_reject_stray_flags
    # These take only --app/--localhost; a stray token used to be silently
    # dropped. Each must now error, exit 1, and show its own usage line.
    {
      "invariants snoozes" => -> { cmd_invariants_snoozes(["--typo"]) },
      "tasks requeue"      => -> { cmd_tasks_requeue(["--typo"]) },
      "deploy status"      => -> { cmd_deploy_status(["--typo"]) },
      "config check"       => -> { cmd_config_check(["--typo"]) },
      "config rollout"     => -> { cmd_config_rollout(["--typo"]) },
      "agent status"       => -> { cmd_agent_status(["--typo"]) },
      "agent runners"      => -> { cmd_agent_runners(["--typo"]) },
      "agent producers"    => -> { cmd_agent_producers(["--typo"]) },
      "agent pause"        => -> { cmd_agent_pause(["--typo"]) },
      "agent resume"       => -> { cmd_agent_resume(["--typo"]) },
      "schema lint"        => -> { cmd_schema_lint(["--typo"]) },
    }.each do |command, callable|
      out, status = capture_stderr_and_exit { callable.call }
      assert_equal 1, status, "#{command}: expected exit 1 on stray flag"
      assert_includes out, "unknown", "#{command}: expected an unknown-arg error"
      assert_includes out, "  Usage: #{usage_for(command)}", "#{command}: wrong/absent usage line"
    end
  end

  # `--repo-dir` names ONE app's schema repo, so on its own it is ambiguous
  # rather than a default — same rule claude-db applies.
  def test_schema_lint_repo_dir_requires_an_app
    out, status = capture_stderr_and_exit { cmd_schema_lint(["--repo-dir", "/tmp/x"]) }
    assert_equal 1, status
    assert_includes out, "needs --app too"
    assert_includes out, "  Usage: #{usage_for('schema lint')}"
  end

  def test_schema_lint_repo_dir_requires_a_value
    out, status = capture_stderr_and_exit { cmd_schema_lint(["--repo-dir"]) }
    assert_equal 1, status
    assert_includes out, "--repo-dir requires a value"
  end

  # ---- USAGE / usage_for stay in sync with the INVOCATIONS map ----

  def test_usage_block_contains_each_invocation_line
    INVOCATIONS.each_value do |line|
      assert_includes USAGE, line, "USAGE missing invocation line: #{line}"
    end
  end

  def test_usage_for_prefixes_dev_and_fails_loud_on_unknown_command
    assert_equal "dev tasks requeue [--app APP] [--localhost]", usage_for("tasks requeue")
    assert_raises(KeyError) { usage_for("nope not a command") }
  end
end
