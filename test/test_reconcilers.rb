#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# The two global reconcilers, as a unit of their own rather than a step of one
# app's release. What is under test is the contract both callers depend on:
# `dev deploy` runs this ONCE for a whole deploy and tells the releases it spawns
# to skip theirs, while a standalone `release` (no deploy above it) still runs
# it. Getting the deferral backwards in either direction is silent — either N
# concurrent `--apply` passes over the same state again (ISS-810), or a release
# after which nothing reconciles at all.
class TestReconcilers < Minitest::Test
  include DevTestSupport

  BIN = "/bin-dir".freeze

  def setup
    @commands = []
    @failing = []
  end

  def teardown
    ENV.delete(Util::QUIET_ENV)
    ENV.delete(Util::LOG_FILE_ENV)
    ENV.delete(Reconcilers::DEFER_ENV)
  end

  def runner
    lambda do |cmd, ignore_error:|
      @commands << { cmd: cmd, ignore_error: ignore_error }
      !@failing.any? { |fragment| cmd.include?(fragment) }
    end
  end

  def reconcilers
    Reconcilers.new(bin_dir: BIN, skip_regenerate_flag: "--skip-generate-json", run: runner)
  end

  # Quiet mode is what turns Util.step into the one-line stage form the deploy
  # display parses.
  def run_quiet(obj)
    out = nil
    Dir.mktmpdir do |dir|
      Util.quiet!(File.join(dir, "reconcile.log"))
      out = capture_stdout { obj.run }
    end
    out
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

  def stages(out)
    out.scan(/^(.+?)\.\.\. (done|failed) \(\d+s\)$/).map { |label, outcome| [label, outcome] }
  end

  def test_runs_both_reconcilers_globally
    run_quiet(reconcilers)
    assert_equal ["#{BIN}/dev features reconcile --apply --skip-generate-json",
                  "#{BIN}/dev issues reconcile --apply --skip-generate-json"],
                 @commands.map { |c| c[:cmd] }
  end

  # Neither may take an --app: they evaluate everything outstanding, which is the
  # whole reason one run covers a deploy of any size.
  def test_neither_reconciler_is_scoped_to_an_app
    run_quiet(reconcilers)
    # Tokenised, not a substring match: `--apply` contains `--app`.
    @commands.each do |c|
      refute_includes c[:cmd].split, "--app", "a reconciler must not be app-scoped: #{c[:cmd]}"
    end
  end

  def test_each_reconciler_is_a_narrated_stage
    assert_equal [
      ["Reconciling feature-flag cleanup", "done"],
      ["Reconciling fixed -> deployed transitions", "done"],
    ], stages(run_quiet(reconcilers))
  end

  # Best-effort in both directions: a failure must not abort the caller (the
  # deploy has already changed production), and must not render as done either.
  def test_a_failing_reconciler_renders_failed_without_aborting
    @failing << "features reconcile"
    assert_equal [
      ["Reconciling feature-flag cleanup", "failed"],
      ["Reconciling fixed -> deployed transitions", "done"],
    ], stages(run_quiet(reconcilers))
  end

  def test_reconcilers_are_run_with_ignore_error
    run_quiet(reconcilers)
    @commands.each { |c| assert c[:ignore_error], "#{c[:cmd]} must not be able to fail a deploy" }
  end

  def test_the_recovery_hint_goes_to_the_log_not_the_stage_stream
    @failing << "issues reconcile"
    Dir.mktmpdir do |dir|
      log = File.join(dir, "reconcile.log")
      Util.quiet!(log)
      out = capture_stdout { reconcilers.run }
      refute_includes out, "run `dev issues reconcile"
      assert_includes File.read(log), "run `dev issues reconcile --apply` later"
    end
  end

  def test_deferred_is_false_without_the_environment_variable
    ENV.delete(Reconcilers::DEFER_ENV)
    refute Reconcilers.deferred?
  end

  # The exact variable a deploy sets on the releases it spawns is the exact one a
  # release reads — asserted through both sides rather than a literal, so a
  # rename cannot leave the halves disagreeing silently.
  def test_the_deploy_environment_is_what_a_release_reads_as_deferred
    Reconcilers.defer_env.each { |k, v| ENV[k] = v }
    assert Reconcilers.deferred?
  end
end
