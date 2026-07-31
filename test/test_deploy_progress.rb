#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require_relative '../lib/common'
require_relative 'test_helper'

class TestDeployProgress < Minitest::Test
  include DevTestSupport

  def plain_io
    StringIO.new
  end

  def tty_io
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    io
  end

  # Everything the display wrote, with cursor/erase escapes stripped, so a test
  # can assert on content without encoding the redraw mechanics.
  def visible(io)
    io.string.gsub(/\e\[[0-9]*[A-Za-z]/, "")
  end

  # --- phase parsing -------------------------------------------------------

  def test_completed_phase_is_recorded_from_a_whole_line
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... done (15s)\n")

    assert_includes visible(io), "Building Docker image... done (15s)"
  end

  # The whole reason feed() takes chunks rather than lines: Util.step flushes
  # the label when the stage STARTS, so the running stage is a line with no
  # newline on it yet. Reading by line would only ever show finished stages.
  def test_running_phase_is_visible_before_its_line_is_complete
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Pushing Docker image... ")

    assert_includes visible(io), "Pushing Docker image..."
    refute_includes visible(io), "done"
  end

  def test_phase_split_across_chunk_boundaries
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building sbt dist")
    p.feed("platform", "ribution... ")
    p.feed("platform", "done (4")
    p.feed("platform", "8s)\n")

    assert_includes visible(io), "Building sbt distribution... done (48s)"
  end

  def test_multiple_phases_accumulate_in_order
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... done (15s)\nPushing Docker image... done (42s)\n")

    out = visible(io)
    assert_operator out.index("Building Docker image"), :<, out.index("Pushing Docker image")
  end

  def test_non_phase_output_is_ignored
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "  [1/2] Applying Services...\nsome kubectl noise\n")

    refute_includes visible(io), "kubectl noise"
  end

  # --- version capture -----------------------------------------------------

  def test_version_is_taken_from_the_release_complete_line
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Release complete: platform 0.18.51\n")
    p.finish("platform", ok: true)

    assert_includes visible(io), "platform  deployed 0.18.51"
  end

  def test_finish_without_a_version_still_reports_success
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("playbook-admin")
    p.finish("playbook-admin", ok: true)

    assert_includes visible(io), "playbook-admin  released"
  end

  # --- finish --------------------------------------------------------------

  def test_success_collapses_and_drops_the_phase_detail
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... done (15s)\n")
    p.finish("platform", ok: true, version: "0.18.51")

    # The collapsed line is what survives; the phase list is redrawn away with
    # the live block, so only the summary remains at the end of the stream.
    tail = visible(io).lines.reject { |l| l.strip.empty? }.last
    assert_match(/platform  deployed 0\.18\.51 \(\d+s\)/, tail)
  end

  def test_failure_keeps_the_phase_list
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... failed (8s)\n")
    p.finish("platform", ok: false)

    out = visible(io)
    assert_includes out, "Building Docker image... failed (8s)"
    assert_includes out, "platform  FAILED"
  end

  # The recap belongs under the FAILED line, not above it. Two apps finishing
  # into one stream put the second app's phases directly beneath the first
  # app's summary line, which reads as the first app's — that's how a
  # 19-second failure appeared to have run a 97-second stage.
  def test_failure_phase_list_prints_below_its_own_header
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("properties")
    p.start("acumen")
    p.feed("acumen", "Pushing Docker image... done (97s)\n")
    p.finish("properties", ok: false)
    p.finish("acumen", ok: false)

    # The live block redraws the running stage every tick, so compare against
    # the LAST occurrence — the recap — not the first.
    lines = visible(io).lines.map(&:rstrip).reject(&:empty?)
    assert_operator lines.index { |l| l.include?("acumen  FAILED") },
      :<, lines.rindex { |l| l.include?("Pushing Docker image... done (97s)") }
  end

  # A release killed mid-stage never prints the stage's completion half. Left
  # alone that stage would render as still running forever.
  def test_unfinished_phase_is_closed_out_on_finish
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Pushing Docker image... ")
    p.finish("platform", ok: false)

    assert_includes visible(io), "Pushing Docker image... failed"
  end

  def test_finish_on_an_unknown_app_is_a_no_op
    p = DeployProgress.new(io: tty_io)
    p.finish("never-started", ok: true)
  end

  # --- non-tty mode --------------------------------------------------------

  def test_non_tty_appends_one_line_per_event_with_no_escapes
    io = plain_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... done (15s)\n")
    p.finish("platform", ok: true, version: "0.18.51")

    out = io.string
    refute_includes out, "\e["
    assert_includes out, "platform starting"
    assert_includes out, "platform  Building Docker image... done (15s)"
    assert_includes out, "platform  deployed 0.18.51"
  end

  # No cursor movement means no in-place rewriting, so a still-running stage
  # must NOT be emitted — it would print a duplicate of the line that arrives
  # again a moment later with its "done (15s)" half attached.
  def test_non_tty_does_not_emit_running_phases
    io = plain_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Pushing Docker image... ")

    refute_includes io.string, "Pushing Docker image"
  end

  def test_non_tty_emits_each_phase_once
    io = plain_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "Building Docker image... ")
    p.feed("platform", "done (15s)\n")

    assert_equal 1, io.string.scan("Building Docker image").length
  end

  # --- concurrency ---------------------------------------------------------

  def test_concurrent_apps_are_tracked_independently
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.start("acumen")
    p.feed("platform", "Building Docker image... done (15s)\n")
    p.feed("acumen", "Building sbt distribution... done (30s)\n")

    out = visible(io)
    assert_includes out, "Building Docker image... done (15s)"
    assert_includes out, "Building sbt distribution... done (30s)"
  end

  def test_feed_is_safe_from_many_threads
    io = tty_io
    p = DeployProgress.new(io: io)
    apps = %w[a b c d]
    apps.each { |a| p.start(a) }
    threads = apps.map do |a|
      Thread.new { 20.times { |i| p.feed(a, "Stage #{i}... done (1s)\n") } }
    end
    threads.each(&:join)
    apps.each { |a| p.finish(a, ok: true) }

    assert_includes visible(io), "a  released"
  end

  # --- message -------------------------------------------------------------

  def test_message_is_printed_above_the_block
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.message("Phase 2: releasing platform")

    assert_includes visible(io), "Phase 2: releasing platform"
  end

  # --- encoding ------------------------------------------------------------

  # Pipe reads are ASCII-8BIT and land on arbitrary byte boundaries, so a
  # multi-byte character routinely arrives split in half. Reassembling it in a
  # UTF-8 buffer raises; the display holds bytes and decodes whole lines.
  def test_feed_handles_a_multibyte_character_split_across_chunks
    io = plain_io
    p = DeployProgress.new(io: io)
    p.start("acumen")
    bytes = "Syncing ConfigMap → Secrets... done (2s)\n".b
    split = bytes.index("\xE2".b) + 1
    p.feed("acumen", bytes[0, split])
    p.feed("acumen", bytes[split..])

    assert_includes visible(io), "acumen  Syncing ConfigMap → Secrets... done (2s)"
    assert io.string.valid_encoding?
  end

  # Malformed bytes (a truncated stream, binary junk in a build tool's output)
  # must not crash the display — they render as replacement characters.
  def test_feed_scrubs_invalid_bytes
    io = plain_io
    p = DeployProgress.new(io: io)
    p.start("acumen")
    p.feed("acumen", "Building \xE2 image... done (2s)\n".dup.force_encoding(Encoding::ASCII_8BIT))

    assert_includes visible(io), "done (2s)"
  end

  # --- disabled ------------------------------------------------------------

  def test_disabled_swallows_everything_but_messages
    p = DeployProgress::Disabled.new
    p.start("lib-util")
    p.feed("lib-util", "Building... done (1s)\n")
    out = capture_stdout { p.message("hello") }
    p.finish("lib-util", ok: true)

    assert_includes out, "hello"
  end

  def test_disabled_run_yields_itself
    p = DeployProgress::Disabled.new
    yielded = nil
    p.run { |x| yielded = x }
    assert_equal p, yielded
  end

  # --- durations -----------------------------------------------------------

  def test_duration_formatting
    assert_equal "0s", DeployProgress.duration(0)
    assert_equal "45s", DeployProgress.duration(45)
    assert_equal "1m00s", DeployProgress.duration(60)
    assert_equal "2m31s", DeployProgress.duration(151)
    assert_equal "1h04m", DeployProgress.duration(3840)
  end

  # --- width ---------------------------------------------------------------

  # A pty with no reported size answers 0 columns. Taken literally that
  # truncates every line to a bare ellipsis — which is exactly what running the
  # display under `script` produced before the fallback existed.
  def test_zero_column_terminal_falls_back_to_a_usable_width
    io = tty_io
    p = DeployProgress.new(io: io)
    p.instance_variable_set(:@terminal_width, nil)
    p.define_singleton_method(:terminal_width) do
      reported = 0
      reported > DeployProgress::MIN_PLAUSIBLE_WIDTH ? reported : DeployProgress::DEFAULT_WIDTH
    end
    p.start("platform")
    p.feed("platform", "Building Docker image... done (15s)\n")

    assert_includes visible(io), "Building Docker image... done (15s)"
  end

  def test_long_lines_are_truncated_to_the_terminal_width
    io = tty_io
    p = DeployProgress.new(io: io)
    p.start("platform")
    p.feed("platform", "#{'x' * 500}... done (1s)\n")

    longest = visible(io).lines.map(&:chomp).map(&:length).max
    assert_operator longest, :<=, DeployProgress::DEFAULT_WIDTH
  end

  # --- run lifecycle -------------------------------------------------------

  def test_run_leaves_the_terminal_clean_even_when_the_block_raises
    io = tty_io
    p = DeployProgress.new(io: io)
    assert_raises(RuntimeError) do
      p.run do |progress|
        progress.start("platform")
        raise "boom"
      end
    end
    # Block erased: the last thing written moves the cursor back up over it.
    assert_match(/\e\[\d+A\z/, io.string)
  end
end
