#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

class TestUtilQuiet < Minitest::Test
  include DevTestSupport

  def setup
    @saved_quiet = ENV[Util::QUIET_ENV]
    @saved_log = ENV[Util::LOG_FILE_ENV]
    ENV.delete(Util::QUIET_ENV)
    ENV.delete(Util::LOG_FILE_ENV)
  end

  def teardown
    ENV[Util::QUIET_ENV] = @saved_quiet
    ENV[Util::LOG_FILE_ENV] = @saved_log
    ENV.delete(Util::QUIET_ENV) if @saved_quiet.nil?
    ENV.delete(Util::LOG_FILE_ENV) if @saved_log.nil?
  end

  def with_quiet
    Dir.mktmpdir do |dir|
      log = File.join(dir, "release.log")
      Util.quiet!(log)
      yield log
    end
  ensure
    ENV.delete(Util::QUIET_ENV)
    ENV.delete(Util::LOG_FILE_ENV)
  end

  def capture_stdout
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    yield
    buf.string
  ensure
    $stdout = old
  end

  def test_not_quiet_by_default
    refute Util.quiet?
  end

  def test_quiet_enables_and_truncates_log
    with_quiet do |log|
      assert Util.quiet?
      assert_equal log, Util.log_file
      assert_equal "", File.read(log)
    end
  end

  def test_run_redirects_output_to_log_in_quiet_mode
    with_quiet do |log|
      Util.run("echo hello-from-test")
      content = File.read(log)
      assert_includes content, "==> echo hello-from-test"
      assert_includes content, "hello-from-test"
    end
  end

  def test_run_passthrough_does_not_redirect_in_quiet_mode
    with_quiet do |log|
      Util.run("true", passthrough: true)
      refute_includes File.read(log), "==> true"
    end
  end

  def test_run_failure_in_quiet_mode_reports_log_path
    with_quiet do |log|
      stderr, status = capture_stderr_and_exit do
        capture_stdout { Util.run("echo boom && false") }
      end
      assert_equal 1, status
      assert_includes stderr, log
      assert_includes stderr, "boom"
    end
  end

  def test_detail_logs_in_quiet_mode_and_prints_otherwise
    with_quiet do |log|
      out = capture_stdout { Util.detail("some detail") }
      assert_equal "", out
      assert_includes File.read(log), "some detail"
    end
    out = capture_stdout { Util.detail("visible detail") }
    assert_includes out, "visible detail"
  end

  def test_step_prints_concise_line_in_quiet_mode
    with_quiet do
      out = capture_stdout { Util.step("Building") { 42 } }
      assert_match(/\ABuilding\.\.\. done \(\d+s\)\n\z/, out)
    end
  end

  def test_step_returns_block_value
    with_quiet do
      value = nil
      capture_stdout { value = Util.step("Building") { 42 } }
      assert_equal 42, value
    end
  end

  def test_step_prints_underlined_header_in_verbose_mode
    out = capture_stdout { Util.step("Building") { } }
    assert_includes out, "Building\n========"
  end

  def test_verbose_flag_parsed
    args = Args.parse(["--app", "platform", "--verbose"])
    assert args.verbose
    args = Args.parse(["--app", "platform"])
    refute args.verbose
  end
end
