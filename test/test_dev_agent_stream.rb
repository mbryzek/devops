#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/stream'
load File.expand_path('../bin/dev', __dir__)

# Reading a live session's output (ISS-949).
#
# The property every test here defends is one property: the line shown for a
# running session must be the last line that MEANS something. A session emits
# six or more `thinking_tokens` events per turn, so the naive implementation —
# tail the file, take the last line — shows noise essentially always, which is
# no better than the `(no output yet)` it replaced.
#
# The fixtures are the real event shapes, captured from
# `claude --print --output-format stream-json --verbose`, not invented ones.
class TestDevAgentStream < Minitest::Test
  include DevTestSupport

  NOISE = { "type" => "system", "subtype" => "thinking_tokens", "estimated_tokens" => 240 }.freeze
  INIT = { "type" => "system", "subtype" => "init", "model" => "claude-opus-5[1m]", "cwd" => "/code/ai/i949" }.freeze

  def assistant(*blocks, at: "2026-08-08T02:15:04.000Z")
    { "type" => "assistant", "timestamp" => at, "message" => { "content" => blocks } }
  end

  def tool_use(name, input) = { "type" => "tool_use", "id" => "toolu_1", "name" => name, "input" => input }

  def tool_error(text)
    { "type" => "user", "timestamp" => "2026-08-08T02:15:05.000Z",
      "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => "toolu_1",
                                     "content" => text, "is_error" => true }] } }
  end

  def result(text: "Done — PR opened.", subtype: "success", **rest)
    { "type" => "result", "subtype" => subtype, "is_error" => false, "result" => text,
      "duration_ms" => 754_000, "num_turns" => 84, "total_cost_usd" => 3.4142 }.merge(rest)
  end

  # A log file holding `entries`, each Hash written as one JSON line and each
  # String written verbatim — which is what stderr looks like in this file.
  def with_log(entries, trailing_newline: true)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stream.jsonl")
      body = entries.map { |e| e.is_a?(String) ? e : JSON.generate(e) }.join("\n")
      File.write(path, trailing_newline ? "#{body}\n" : body)
      yield path
    end
  end

  # ---- the bug: noise must not be what a human sees ----

  def test_thinking_tokens_render_nothing_so_the_last_real_line_wins
    with_log([INIT, assistant(tool_use("Bash", { "command" => "sbt test" })), NOISE, NOISE, NOISE]) do |path|
      assert_equal "→ Bash sbt test", Agent::Stream.last_line(path)
    end
  end

  def test_a_log_of_pure_noise_reports_the_session_start_not_a_json_blob
    with_log([INIT, NOISE, NOISE]) do |path|
      assert_equal "session started · model=claude-opus-5[1m] · cwd=/code/ai/i949", Agent::Stream.last_line(path)
    end
  end

  # The window is bounded so `dev agent status` does not read megabytes per
  # claim; a stretch of noise longer than the first window must still not hide
  # the last real line behind it.
  def test_a_real_line_buried_under_more_noise_than_one_window_is_still_found
    noise = Array.new(1_200) { NOISE }
    with_log([assistant(tool_use("Bash", { "command" => "git push" }))] + noise) do |path|
      assert_operator File.size(path), :>, 64 * 1024
      assert_equal "→ Bash git push", Agent::Stream.last_line(path)
    end
  end

  # ---- what each kind of event says ----

  def test_tool_calls_render_as_the_thing_they_are_doing
    lines = Agent::Stream.render_event(assistant(tool_use("Read", { "file_path" => "/code/lib/dao.scala" })))
    assert_equal ["→ Read /code/lib/dao.scala"], lines
  end

  def test_a_tool_input_with_no_known_argument_key_still_renders_something
    lines = Agent::Stream.render_event(assistant(tool_use("SomeNewTool", { "whatever" => "the value" })))
    assert_equal ["→ SomeNewTool the value"], lines
  end

  def test_assistant_text_renders_and_thinking_does_not
    event = assistant({ "type" => "thinking", "thinking" => "secret reasoning" },
                      { "type" => "text", "text" => "Rebasing onto main.\n\nThen regenerating." })
    assert_equal ["Rebasing onto main.", "Then regenerating."], Agent::Stream.render_event(event)
  end

  def test_a_failing_tool_is_surfaced_and_a_passing_one_is_not
    assert_equal ["✗ tool error: relation \"clubs\" does not exist"],
                 Agent::Stream.render_event(tool_error("relation \"clubs\" does not exist"))

    passing = { "type" => "user", "message" => { "content" => [{ "type" => "tool_result", "content" => "ok",
                                                                 "is_error" => false }] } }
    assert_empty Agent::Stream.render_event(passing)
  end

  def test_a_failing_hook_is_surfaced_and_a_passing_one_is_not
    failed = { "type" => "system", "subtype" => "hook_response", "hook_name" => "PreToolUse", "exit_code" => 2 }
    assert_equal ["hook PreToolUse failed (exit 2)"], Agent::Stream.render_event(failed)
    assert_empty Agent::Stream.render_event(failed.merge("exit_code" => 0))
  end

  # The summary is deliberately LAST, so that it — and not a trailing fragment of
  # the final prose — is what `last_line` reports for a finished session.
  def test_the_result_event_ends_with_how_the_run_ended
    with_log([result]) do |path|
      assert_equal "● success · 12m34s · 84 turns · $3.41", Agent::Stream.last_line(path)
    end
  end

  # A successful `result` repeats the final assistant text verbatim, and the
  # stream already rendered it — printing it again ends every log with the same
  # paragraph twice. A FAILING one is the only place its reason appears.
  def test_the_final_text_is_repeated_only_when_the_run_failed
    said = assistant({ "type" => "text", "text" => "Done — PR opened." })

    with_log([said, result]) do |path|
      assert_equal 1, Agent::Stream.render_file(path, stamp: false).count("Done — PR opened.")
    end

    with_log([result(text: "Credit balance too low", subtype: "error_during_execution", "is_error" => true)]) do |p|
      assert_includes Agent::Stream.render_file(p), "Credit balance too low"
    end
  end

  # ---- the file is stderr as well as JSON, and is being written while read ----

  # ISS-783's entire session log is the two words "Execution error". A renderer
  # that only understood JSON would show nothing for the session that most needs
  # explaining.
  def test_non_json_output_is_shown_verbatim
    with_log([INIT, "Execution error"]) do |path|
      assert_equal "Execution error", Agent::Stream.last_line(path)
    end
  end

  def test_a_half_written_trailing_line_is_not_rendered_as_garbage
    entries = [assistant(tool_use("Bash", { "command" => "sbt test" })), '{"type":"assis']
    with_log(entries, trailing_newline: false) do |path|
      assert_equal "→ Bash sbt test", Agent::Stream.last_line(path)
    end
  end

  def test_an_unknown_event_type_renders_nothing_rather_than_raising
    assert_empty Agent::Stream.render_event({ "type" => "some_future_thing", "payload" => {} })
  end

  def test_an_empty_log_has_no_last_line
    with_log([]) { |path| assert_nil Agent::Stream.last_line(path) }
  end

  # ---- the log view ----

  def test_render_file_stamps_lines_and_raw_returns_the_underlying_jsonl
    with_log([INIT, assistant(tool_use("Bash", { "command" => "git push" }))]) do |path|
      rendered = Agent::Stream.render_file(path)
      assert_match(/\A\[\d\d:\d\d:\d\d\] → Bash git push\z/, rendered.last)

      raw = Agent::Stream.render_file(path, raw: true)
      assert_equal JSON.parse(raw.last)["type"], "assistant"
    end
  end

  # ---- was the session refused before it ever ran? (ISS-1129) ----
  #
  # These fixtures are the real events from ISS-993's log on 2026-08-08: a
  # rejected `rate_limit_event`, one assistant line of prose, and a terminal
  # `result` carrying `api_error_status`. Four tenths of a second, exit 1, and
  # nothing to show for it — which every other signal reads as a failed attempt.

  REJECTED = { "type" => "rate_limit_event",
               "rate_limit_info" => { "status" => "rejected", "rateLimitType" => "five_hour",
                                      "resetsAt" => 1_786_165_200 } }.freeze
  ALLOWED = { "type" => "rate_limit_event",
              "rate_limit_info" => { "status" => "allowed", "resetsAt" => 1_786_165_200 } }.freeze

  def refusal(**rest)
    result(text: "You've hit your session limit · resets 1am (America/New_York)", is_error: true,
           api_error_status: 429, terminal_reason: "api_error", duration_ms: 461, **rest)
  end

  def test_a_refused_session_is_reported_with_the_reset_instant
    with_log([INIT, REJECTED, refusal]) do |path|
      limit = Agent::Stream.usage_limit(path)
      assert limit, "a terminal 429 is the API refusing to start the session"
      assert_match(/hit your session limit/, limit["message"])
      assert_equal Time.at(1_786_165_200).utc, limit["resets_at"]
    end
  end

  # THE CASE THAT MUST NOT FIRE. A session throttled mid-run and then finishing
  # its work is a success; classifying it as a refusal would hand a delivered PR
  # back to the queue and stand the runner down on a limit that let it through.
  def test_a_rate_limit_event_in_a_session_that_finished_is_not_a_refusal
    with_log([INIT, REJECTED, assistant(tool_use("Bash", { "command" => "gh pr create" })), result]) do |path|
      assert_nil Agent::Stream.usage_limit(path)
    end
  end

  def test_an_ordinary_failure_is_not_a_refusal
    with_log([INIT, result(text: "compile failed", subtype: "error_during_execution", is_error: true)]) do |path|
      assert_nil Agent::Stream.usage_limit(path)
    end
  end

  # A `resetsAt` rides on rate-limit events that were ALLOWED too. Taking one
  # would invent a cooldown out of a session nobody refused.
  def test_only_a_rejected_rate_limit_event_supplies_the_reset_instant
    with_log([INIT, ALLOWED, refusal]) do |path|
      assert_nil Agent::Stream.usage_limit(path)["resets_at"]
    end
  end

  # The executor appends, so one file can hold more than one attempt. How the
  # run ENDED is the last result in it, not the first.
  def test_the_last_result_decides
    with_log([INIT, refusal, INIT, result]) do |path|
      assert_nil Agent::Stream.usage_limit(path)
    end
    with_log([INIT, result, INIT, REJECTED, refusal]) do |path|
      assert Agent::Stream.usage_limit(path)
    end
  end

  def test_a_missing_or_empty_log_is_not_a_refusal
    assert_nil Agent::Stream.usage_limit("/nonexistent/stream.jsonl")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stream.jsonl")
      File.write(path, "")
      assert_nil Agent::Stream.usage_limit(path)
    end
  end

  # ---- the spawn side ----

  def test_only_a_streaming_session_asks_for_stream_json
    plain = headless_claude_argv
    refute_includes plain, "stream-json"

    streaming = headless_claude_argv(stream: true)
    assert_equal ["--output-format", "stream-json"], streaming[streaming.index("--output-format"), 2]
    # The CLI rejects stream-json without it, so its absence is not cosmetic.
    assert_includes streaming, "--verbose"
  end

  # The tick is the caller that must stream: its sessions run for hours and are
  # the ones `dev agent status` reports on.
  def test_the_dispatcher_spawns_streaming_sessions
    source = File.read(File.expand_path('../bin/dev', __dir__))
    assert_includes source, "claude_argv: headless_claude_argv(stream: true)"
  end
end
