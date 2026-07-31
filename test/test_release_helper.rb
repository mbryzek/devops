#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# ReleaseHelper's two command runners under quiet mode.
#
# Quiet mode turns the release's stdout into a stage stream — Util.step's
# "label... done (12s)" lines, which `dev deploy` parses to drive its live phase
# display. A runner that streams a subprocess's own output onto that stream at
# best buries the stages in noise and at worst gets read as one. So in quiet
# mode both runners hand off to Util.run, which appends everything to the
# release log; outside quiet mode nothing about them changes.
class TestReleaseHelper < Minitest::Test
  include DevTestSupport

  # ReleaseHelper#initialize loads the devops app config from the checkout
  # directory name, which needs the whole config pipeline. The runners under
  # test touch none of it, so allocate the object without running the
  # constructor rather than standing up a fake app.
  def helper
    ReleaseHelper.allocate
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

  def test_run_sends_output_to_the_log_and_nothing_to_stdout_in_quiet_mode
    with_quiet do |log|
      out = capture_stdout { helper.run("echo from-run") }
      assert_equal "", out
      assert_includes File.read(log), "from-run"
    end
  end

  # run_system exists to keep a command's output on the terminal (npm and
  # wrangler narrate themselves). Quiet mode is precisely when we do not want
  # that, so the distinction has to disappear there.
  def test_run_system_sends_output_to_the_log_and_nothing_to_stdout_in_quiet_mode
    with_quiet do |log|
      out = capture_stdout { helper.run_system("echo from-run-system") }
      assert_equal "", out
      assert_includes File.read(log), "from-run-system"
    end
  end

  # With stdout redirected to the log, a command that decides to prompt would
  # block on a prompt nobody can see. Closing stdin makes it fail instead.
  def test_run_system_closes_stdin_in_quiet_mode
    with_quiet do |log|
      capture_stdout { helper.run_system("cat") }
      assert_equal "", File.read(log).lines.grep_v(/\A==>/).join.strip,
        "a command reading stdin must get EOF immediately, not hang"
    end
  end

  # A stage that dies must still abort the release, and must say where to look.
  def test_run_system_failure_in_quiet_mode_aborts_and_names_the_log
    with_quiet do |log|
      stderr, status = capture_stderr_and_exit do
        capture_stdout { helper.run_system("echo boom && false") }
      end
      assert_equal 1, status
      assert_includes stderr, log
      assert_includes stderr, "boom"
    end
  end

  # Outside quiet mode run_system still echoes the command and leaves its output
  # on the terminal, which is what a by-hand `release-sveltekit --verbose`
  # relies on. (A no-op command: the interesting part is the echo, and the
  # subprocess writes to fd 1 rather than the captured $stdout regardless.)
  def test_run_system_still_echoes_the_command_when_not_quiet
    refute Util.quiet?
    out = capture_stdout { helper.run_system(": streamed-marker") }
    assert_includes out, ": streamed-marker"
  end
end

# The concise release scripts and DeployProgress are coupled through two things
# neither file can enforce on the other: the script has to opt into quiet mode
# (or it emits no stages at all and the display falls back to a bare clock), and
# it has to end with the exact "Release complete: <app> <version>" wording that
# DeployProgress::VERSION_RE reads the released version out of. Both were the
# actual gap that left every Cloudflare app blank in `dev deploy`.
class TestReleaseScriptsNarrateThemselves < Minitest::Test
  CONCISE_RELEASE_SCRIPTS = %w[release-scala release-sveltekit release-elm].freeze

  def source(script)
    File.read(File.expand_path("../bin/#{script}", __dir__))
  end

  def test_every_concise_release_script_enables_quiet_mode
    CONCISE_RELEASE_SCRIPTS.each do |script|
      assert_includes source(script), "Util.quiet!",
        "#{script} must enable quiet mode or it emits no stages for dev deploy to show"
    end
  end

  def test_every_concise_release_script_announces_the_released_version
    CONCISE_RELEASE_SCRIPTS.each do |script|
      line = source(script).lines.find { |l| l.include?("Release complete:") }
      refute_nil line, "#{script} must end with a Release complete: line"
      # Prove the emitted wording is one DeployProgress actually parses, rather
      # than trusting that the two files still agree.
      rendered = line[/puts "(.*)"/, 1].to_s
        .gsub('#{helper.app}', "properties").gsub('#{app}', "properties")
        .gsub('#{tag}', "0.0.51").gsub('#{version}', "0.0.51")
      assert_match DeployProgress::VERSION_RE, rendered,
        "#{script}'s completion line must match DeployProgress::VERSION_RE"
    end
  end
end
