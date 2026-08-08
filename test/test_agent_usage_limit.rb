#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'time'
require_relative 'test_helper'
require 'agent/usage_limit'

# Standing down while the Claude API is refusing to start sessions (ISS-1129).
#
# `Agent::Outcome` makes ONE refusal harmless. This is what stops the runner
# doing it thirty more times: on 2026-08-08 the tick claimed straight through a
# five-hour limit, and because every refused session read as a failed attempt,
# three issues spent their whole retry budget inside ninety seconds and landed in
# `needs_input` — the status `dev issues claim` never offers again.
class TestAgentUsageLimit < Minitest::Test
  NOW = Time.utc(2026, 8, 8, 3, 19, 0)

  def with_state
    Dir.mktmpdir do |dir|
      original = ENV["DEV_AGENT_STATE_DIR"]
      ENV["DEV_AGENT_STATE_DIR"] = dir
      begin
        yield dir
      ensure
        original.nil? ? ENV.delete("DEV_AGENT_STATE_DIR") : ENV["DEV_AGENT_STATE_DIR"] = original
      end
    end
  end

  def refusal(resets_at: Time.utc(2026, 8, 8, 5, 0, 0))
    { "message" => "You've hit your session limit · resets 1am", "resets_at" => resets_at }
  end

  # Nothing recorded means nothing to wait for: an ordinary runner claims.
  def test_a_machine_that_has_never_been_refused_claims
    with_state { assert_nil Agent::UsageLimit.active(now: NOW) }
  end

  def test_the_cooldown_runs_to_the_reset_the_api_stated
    with_state do
      assert_equal Time.utc(2026, 8, 8, 5, 0, 0), Agent::UsageLimit.record(refusal, now: NOW)
      assert_equal Time.utc(2026, 8, 8, 5, 0, 0), Agent::UsageLimit.active(now: NOW)
      assert_nil Agent::UsageLimit.active(now: Time.utc(2026, 8, 8, 5, 0, 1)),
                 "the runner has to start claiming again on its own"
    end
  end

  # A refusal that named no reset instant is still a refusal. Standing down for a
  # short fixed window costs one idle stretch; claiming on regardless is the
  # behaviour that spent three issues.
  def test_a_refusal_with_no_reset_instant_still_stands_the_runner_down
    with_state do
      until_time = Agent::UsageLimit.record(refusal(resets_at: nil), now: NOW)
      assert_equal NOW + Agent::UsageLimit::DEFAULT_COOLDOWN_SECONDS, until_time
      assert Agent::UsageLimit.active(now: NOW)
    end
  end

  # A reset already in the past is not "no cooldown" — the refusal happened
  # either way — and a reset absurdly far ahead must not park the fleet.
  def test_a_nonsensical_reset_instant_falls_back_to_a_bounded_window
    with_state do
      stale = Agent::UsageLimit.record(refusal(resets_at: NOW - 3600), now: NOW)
      assert_equal NOW + Agent::UsageLimit::DEFAULT_COOLDOWN_SECONDS, stale

      skewed = Agent::UsageLimit.record(refusal(resets_at: NOW + (30 * 24 * 3600)), now: NOW)
      assert_equal NOW + Agent::UsageLimit::MAX_COOLDOWN_SECONDS, skewed
    end
  end

  # A throttle is a cache, and a corrupt cache must never be able to stop the
  # fleet claiming. Failing OPEN is right here for the same reason failing CLOSED
  # is right for `paused`: the worst this costs is one refused session, and a
  # refused session now costs the issue nothing.
  def test_an_unreadable_throttle_does_not_stop_the_runner
    with_state do
      File.write(Agent::UsageLimit.file, "{ not json")
      assert_nil Agent::UsageLimit.active(now: NOW)
      File.write(Agent::UsageLimit.file, '{"until":"whenever"}')
      assert_nil Agent::UsageLimit.active(now: NOW)
    end
  end

  # Two sessions refused in the same tick record the same window twice, and a
  # later refusal legitimately extends it. Neither may raise.
  def test_recording_is_idempotent_and_last_write_wins
    with_state do
      Agent::UsageLimit.record(refusal, now: NOW)
      later = Agent::UsageLimit.record(refusal(resets_at: Time.utc(2026, 8, 8, 6, 0, 0)), now: NOW)
      assert_equal later, Agent::UsageLimit.active(now: NOW)
    end
  end

  # What the executor already wrote is the only evidence, and it is read from the
  # issue's own session log — no second source, and no network call on this path.
  def test_detect_reads_the_issues_session_log
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_LOG_ROOT"]
      ENV["DEV_AGENT_LOG_ROOT"] = root
      begin
        path = Agent::Paths.session_log("993")
        Agent::Paths.mkdir_p(File.dirname(path))
        File.write(path, <<~JSONL)
          {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1786165200}}
          {"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your session limit"}
        JSONL
        limit = Agent::UsageLimit.detect("993")
        assert_match(/session limit/, limit["message"])
        assert_equal Time.at(1_786_165_200).utc, limit["resets_at"]
        assert_nil Agent::UsageLimit.detect("994"), "an issue with no log was not refused"
      ensure
        original.nil? ? ENV.delete("DEV_AGENT_LOG_ROOT") : ENV["DEV_AGENT_LOG_ROOT"] = original
      end
    end
  end
end
