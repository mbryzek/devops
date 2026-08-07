#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Notify — the push channel, and the two ways it was silent (ISS-535).
#
# `openclaw` is not installed on the runners, so every push this dispatcher has
# ever attempted has been a no-op. It returned `false`, every caller discarded
# it, and nothing anywhere recorded that the fleet had no notification channel at
# all. What made that survivable rather than a loss of information is BACKSTOPS,
# and the point of this file is that BACKSTOPS is checked rather than believed:
# a push whose fact lives nowhere durable is a push whose loss is real, and it is
# the one thing here a comment cannot catch.
class TestDevAgentNotify < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |root|
      previous = ENV["DEV_AGENT_STATE_DIR"]
      no_notify = ENV.delete("DEV_AGENT_NO_NOTIFY")
      ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
      yield root
    ensure
      ENV["DEV_AGENT_STATE_DIR"] = previous
      ENV["DEV_AGENT_NO_NOTIFY"] = no_notify
    end
  end

  # Stubs the ONE line that shells out, so every outcome below is the real
  # `event` deciding, not a re-implementation of it. `:hung` is a push that
  # outlived its deadline (ISS-740) — a nudge channel is the last thing worth
  # wedging a runner for, and every push has a durable backstop precisely
  # because it may not arrive.
  def with_openclaw(result, &block)
    stub_shell(lambda { |cmd, _opts|
      raise Errno::ENOENT, cmd.first if result == :absent
      next shell_result(timed_out: true, timeout: Agent::Notify::TIMEOUT_SECONDS) if result == :hung
      shell_result(exitstatus: result == :ok ? 0 : 1)
    }, &block)
  end

  # ---- the three outcomes are three different things ----

  def test_a_missing_binary_is_unavailable_not_merely_false
    with_state_dir do
      with_openclaw(:absent) do
        assert_equal Agent::Notify::UNAVAILABLE, Agent::Notify.event("pr_ready", "hi")
      end
    end
  end

  def test_a_refusing_binary_is_failed
    with_state_dir do
      with_openclaw(:error) { assert_equal Agent::Notify::FAILED, Agent::Notify.event("pr_ready", "hi") }
    end
  end

  def test_a_working_binary_is_delivered
    with_state_dir do
      with_openclaw(:ok) { assert_equal Agent::Notify::DELIVERED, Agent::Notify.event("pr_ready", "hi") }
    end
  end

  # A push that never returns is a push that did not arrive, which is FAILED —
  # and, before ISS-740, was a tick that never returned either.
  def test_a_hanging_binary_is_failed_rather_than_holding_the_tick
    with_state_dir do
      with_openclaw(:hung) { assert_equal Agent::Notify::FAILED, Agent::Notify.event("pr_ready", "hi") }
    end
  end

  def test_the_kill_switch_reports_itself_rather_than_pretending_to_deliver
    with_state_dir do
      ENV["DEV_AGENT_NO_NOTIFY"] = "1"
      # Not stubbed on purpose: a suppressed push must not shell out at all.
      assert_equal Agent::Notify::DISABLED, Agent::Notify.event("pr_ready", "hi")
    end
  end

  # Only the two undelivered-and-nobody-asked-for-it outcomes are worth a line.
  # A machine someone silenced announcing its silence every 30 seconds is the
  # noise this module's deliberately short list exists to avoid.
  def test_only_failed_and_unavailable_are_reportable
    assert Agent::Notify.reportable?(Agent::Notify::UNAVAILABLE)
    assert Agent::Notify.reportable?(Agent::Notify::FAILED)
    refute Agent::Notify.reportable?(Agent::Notify::DISABLED)
    refute Agent::Notify.reportable?(Agent::Notify::DELIVERED)
  end

  # ---- the window is consumed by the ATTEMPT, not by the call ----

  def test_a_failed_push_does_not_consume_the_window
    with_state_dir do
      attempts = 0
      2.times do
        Agent::Notify.once("agent_error", "checkout_pull", now: Time.utc(2026, 8, 5, 10)) do
          attempts += 1
          Agent::Notify::FAILED
        end
      end
      assert_equal 2, attempts, "a refusal is transient — the retry it needs must not be throttled away"
    end
  end

  # The complement, and the reason UNAVAILABLE is not treated as transient: a box
  # with no `openclaw` will not grow one before the next tick, and the tick runs
  # every 30 seconds.
  def test_an_unavailable_channel_does_consume_the_window
    with_state_dir do
      attempts = 0
      2.times do
        Agent::Notify.once("agent_error", "checkout_pull", now: Time.utc(2026, 8, 5, 10)) do
          attempts += 1
          Agent::Notify::UNAVAILABLE
        end
      end
      assert_equal 1, attempts, "retrying a channel that does not exist costs a process and cannot succeed"
    end
  end

  def test_a_delivered_push_throttles_until_the_window_passes
    with_state_dir do
      attempts = 0
      run = lambda do |now|
        Agent::Notify.once("agent_error", "checkout_pull", window_seconds: 3600, now: now) do
          attempts += 1
          Agent::Notify::DELIVERED
        end
      end
      run.call(Time.utc(2026, 8, 5, 10))
      run.call(Time.utc(2026, 8, 5, 10, 30))
      assert_equal 1, attempts
      run.call(Time.utc(2026, 8, 5, 11, 1))
      assert_equal 2, attempts, "the window must reopen once it has actually elapsed"
    end
  end

  def test_entries_older_than_a_month_are_pruned
    with_state_dir do
      Agent::Paths.write_json(Agent::Paths.notified_file, { "gave_up:1" => Time.utc(2026, 1, 1).iso8601 }, mode: 0600)
      Agent::Notify.once("gave_up", "2", now: Time.utc(2026, 8, 5)) { Agent::Notify::DELIVERED }
      assert_equal ["gave_up:2"], Agent::Paths.read_json(Agent::Paths.notified_file).keys
    end
  end

  # ---- every push names what carries the fact without it ----

  # The contract that makes a missing `openclaw` cost attention rather than
  # information. Scanned out of the source rather than listed here, because a
  # second hand-maintained list is exactly what drifts: the failure this guards
  # is someone adding a push whose fact lives nowhere else, which by definition
  # nobody notices from the push side.
  # All three ways a kind can enter the system, not just the tick's `push`
  # helper: a call site that reached past it straight to `Notify.event` would
  # otherwise be invisible here, which is the hole rather than the guard.
  def pushed_kinds
    sources = Dir[File.expand_path("../lib/agent/*.rb", __dir__)] + [File.expand_path("../bin/dev", __dir__)]
    sources.flat_map { |f| File.read(f).scan(/(?:^\s*push|Notify\.once|Notify\.event)\("([a-z_]+)"/) }.flatten.uniq
  end

  def test_every_kind_the_tick_pushes_has_a_backstop
    assert_equal pushed_kinds.sort, Agent::Notify::BACKSTOPS.keys.sort,
                 "add the new kind to Agent::Notify::BACKSTOPS naming what holds the fact when openclaw is absent, " \
                 "or drop the stale entry"
  end

  def test_no_backstop_is_left_blank
    Agent::Notify::BACKSTOPS.each do |kind, backstop|
      refute_empty backstop.to_s.strip, "#{kind} has no durable backstop — then its loss is real, not just late"
    end
  end

  # ISS-535's actual deletion, pinned from the Notify side too: runner-offline
  # was the one push with no durable record on this side, and a runner is the one
  # place it cannot come from (an offline machine cannot report itself; a
  # one-runner fleet has no peer). It belongs to CheckAgentRunnerHealthProcessor.
  def test_runner_offline_is_not_a_push_this_side_sends
    refute_includes Agent::Notify::BACKSTOPS.keys, "runner_offline"
    refute_includes pushed_kinds, "runner_offline"
  end

  def test_explain_names_both_the_reason_and_the_backstop
    line = Agent::Notify.explain("pr_ready", Agent::Notify::UNAVAILABLE)
    assert_match(/no `openclaw` on this machine/, line)
    assert_match(/moves to `fixed` with the PR url/, line)
  end

  def test_explain_calls_out_a_kind_with_no_backstop
    assert_match(/no durable backstop/, Agent::Notify.explain("invented", Agent::Notify::FAILED))
  end

  # ---- the status line ----

  def test_channel_path_finds_the_binary_on_a_given_path
    Dir.mktmpdir do |root|
      bin = File.join(root, "openclaw")
      File.write(bin, "#!/bin/sh\n")
      File.chmod(0755, bin)
      assert_equal bin, Agent::Notify.channel_path(path: "#{root}::/nope")
      assert_nil Agent::Notify.channel_path(path: "/nope")
    end
  end

  # A non-executable file of the right name is not a channel — the same mistake
  # as trusting `File.exist?` for a binary.
  def test_channel_path_ignores_a_non_executable
    Dir.mktmpdir do |root|
      File.write(File.join(root, "openclaw"), "not a program")
      File.chmod(0644, File.join(root, "openclaw"))
      assert_nil Agent::Notify.channel_path(path: root)
    end
  end
end
