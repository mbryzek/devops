#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# The post-deploy phase of a release: spec publish, changelog, reconcilers.
#
# These steps run after the rollout the release script already waited for, and
# they are slow — `api publish` alone takes ~45s for platform. They used to
# narrate nothing, so `dev deploy` showed the app on a ticking clock with no
# stage under it for the last minute-plus of every release, which is
# indistinguishable from a hang. What is under test is therefore the narration:
# one Util.step stage per step, in the exact "label... done (12s)" form
# lib/deploy_progress.rb parses, and a best-effort step that fails rendering as
# failed rather than silently as done.
class TestPostRelease < Minitest::Test
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

  # Records every command instead of running it. Commands listed in @failing
  # report failure, which is how Util.run behaves under :ignore_error.
  def runner
    lambda do |cmd, ignore_error:|
      @commands << { cmd: cmd, ignore_error: ignore_error }
      !@failing.any? { |fragment| cmd.include?(fragment) }
    end
  end

  def post_release(app: "platform", owns_specs: true)
    PostRelease.new(app: app, bin_dir: BIN, skip_regenerate_flag: "--skip-generate-json",
                    owns_specs: owns_specs, run: runner)
  end

  # Quiet mode is what turns Util.step into the one-line stage form; a release
  # under `dev deploy` is always in it by the time these steps run.
  def run_quiet(pr)
    out = nil
    Dir.mktmpdir do |dir|
      Util.quiet!(File.join(dir, "post-release.log"))
      out = capture_stdout { pr.run }
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

  def test_every_step_is_narrated_as_a_stage
    out = run_quiet(post_release(app: "playbook-app"))
    assert_equal [
      ["Publishing apibuilder specs", "done"],
      ["Recording changelog", "done"],
      ["Reconciling feature-flag cleanup", "done"],
      ["Reconciling fixed -> deployed transitions", "done"],
    ], stages(out)
  end

  # Nothing but the stage lines may reach stdout: the parent reads a dangling
  # "label... " as "this stage is running now", so any other output on that
  # stream lands mid-line and the stage stops being recognizable.
  def test_nothing_but_stages_reaches_stdout
    out = run_quiet(post_release)
    out.each_line do |line|
      assert_match(/\A.+?\.\.\. (done|failed) \(\d+s\)\n\z/, line,
                   "stray output on the stage stream: #{line.inspect}")
    end
  end

  # The point of the stages: `dev deploy`'s live display must recognize them.
  # Asserted through DeployProgress itself rather than a copy of its regex, so a
  # format change on either side fails here. Its non-TTY mode emits one line per
  # stage it parsed — a stage it did not parse simply never appears.
  def test_the_deploy_display_recognizes_every_stage
    io = StringIO.new
    progress = DeployProgress.new(io: io)
    progress.start("platform")
    # Byte-at-a-time: the display reads pipe chunks, not lines, and the whole
    # protocol rests on a stage's label arriving before its "done" half does.
    run_quiet(post_release(app: "playbook-app")).each_char { |c| progress.feed("platform", c) }

    seen = io.string.lines.grep(/platform  /).map(&:strip)
    assert_equal [
      "platform  Publishing apibuilder specs... done (0s)",
      "platform  Recording changelog... done (0s)",
      "platform  Reconciling feature-flag cleanup... done (0s)",
      "platform  Reconciling fixed -> deployed transitions... done (0s)",
    ], seen
  end

  def test_specs_are_not_published_when_the_checkout_owns_none
    out = run_quiet(post_release(owns_specs: false))
    refute_includes stages(out).map(&:first), "Publishing apibuilder specs"
    refute(@commands.any? { |c| c[:cmd].include?("api publish") })
  end

  # Only the tracked playbook apps feed the changelog pipeline.
  def test_changelog_runs_only_for_tracked_apps
    run_quiet(post_release(app: "playbook-admin"))
    assert(@commands.any? { |c| c[:cmd] == "#{BIN}/dev changelog --app playbook-admin --skip-generate-json" })

    @commands.clear
    run_quiet(post_release(app: "platform"))
    refute(@commands.any? { |c| c[:cmd].include?("changelog") })
  end

  # A standalone `release` is the whole deploy, so it still reconciles — for
  # every app, not just the ones the reconcilers happen to be about.
  def test_a_standalone_release_reconciles_whatever_app_it_released
    run_quiet(post_release(app: "acumen"))
    %w[features issues].each do |command|
      assert(@commands.any? { |c| c[:cmd] == "#{BIN}/dev #{command} reconcile --apply --skip-generate-json" },
             "#{command} reconcile must run after a standalone release")
    end
  end

  # Under `dev deploy` the reconcilers belong to the deploy, which runs them once
  # after every app has released. A release that ran its own too would be back to
  # N concurrent `--apply` passes over the same state (ISS-810).
  def test_a_release_under_dev_deploy_defers_the_reconcilers
    ENV[Reconcilers::DEFER_ENV] = "1"
    out = run_quiet(post_release(app: "playbook-app"))
    assert_equal [
      ["Publishing apibuilder specs", "done"],
      ["Recording changelog", "done"],
    ], stages(out)
    refute(@commands.any? { |c| c[:cmd].include?("reconcile") },
           "no reconcile may run inside a release `dev deploy` spawned")
  end

  # A reconcile hiccup must never fail a release that has already deployed — but
  # it must not be reported as done either. Before the stages existed, the whole
  # failure was one `warn` line lost in the release log.
  def test_a_failed_best_effort_step_renders_failed_without_aborting
    @failing << "features reconcile"
    out = run_quiet(post_release)
    assert_equal [
      ["Publishing apibuilder specs", "done"],
      ["Reconciling feature-flag cleanup", "failed"],
      ["Reconciling fixed -> deployed transitions", "done"],
    ], stages(out)
  end

  def test_best_effort_failure_detail_goes_to_the_log_not_the_stage_stream
    @failing << "issues reconcile"
    Dir.mktmpdir do |dir|
      log = File.join(dir, "post-release.log")
      Util.quiet!(log)
      out = capture_stdout { post_release.run }
      refute_includes out, "run `dev issues reconcile"
      assert_includes File.read(log), "run `dev issues reconcile --apply` later"
    end
  end

  # The publish is deliberately NOT best-effort: a deployed API whose specs
  # failed to publish is exactly the drift the hermetic design exists to prevent.
  def test_publishing_specs_is_not_best_effort
    run_quiet(post_release)
    publish = @commands.find { |c| c[:cmd].include?("api publish") }
    refute publish[:ignore_error], "a failed spec publish must fail the release"
  end

  # The production call shape. Everything else here injects `run` and
  # `owns_specs`, so a rename of the arguments bin/release actually passes would
  # otherwise surface only at release time — after the deploy, when the release
  # has already changed production.
  def test_constructs_with_the_arguments_bin_release_passes
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        pr = PostRelease.new(app: "platform", bin_dir: "/bin-dir",
                             skip_regenerate_flag: Config::SKIP_REGENERATE_FLAG)
        assert_instance_of PostRelease, pr
      end
    end
  end

  # A checkout with no .api config owns no specs — every frontend, and every
  # repo that consumes the registry without publishing to it.
  def test_owns_specs_is_false_without_an_api_config
    Dir.mktmpdir { |dir| refute PostRelease.owns_specs?(dir) }
  end

  def test_best_effort_steps_are_run_with_ignore_error
    run_quiet(post_release(app: "playbook-www"))
    @commands.reject { |c| c[:cmd].include?("api publish") }.each do |c|
      assert c[:ignore_error], "#{c[:cmd]} must not be able to fail a deployed release"
    end
  end
end
