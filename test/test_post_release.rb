#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# The post-deploy phase of ONE release, which no longer runs the post-deploy work
# — it files it (ISS-814). What is under test is therefore the two things a
# release still owes:
#
#  1. WHO files. A standalone `release` is the whole deploy, so it files for its
#     one app; a release `dev deploy` spawned files nothing, because the deploy
#     files ONE epic for every app it released. Getting that backwards is silent
#     in both directions — five epics for one deploy, or nothing filed at all.
#  2. That the filing is narrated as a stage and is NOT best-effort. `api publish`
#     used to fail the release when it failed; an unfiled publish is exactly as
#     silent as an unrun one, so a filing failure has to stop the release and say
#     what to run by hand.
class TestPostRelease < Minitest::Test
  include DevTestSupport

  # Stands in for PostDeployWork so a test never files against the real tracker.
  FakeWork = Struct.new(:filed, :error, :tasks) do
    def any? = true

    def file!
      raise error if error
      filed
    end

    def manual_commands = ["api publish", "dev issues reconcile --apply"]
  end

  def teardown
    ENV.delete(Util::QUIET_ENV)
    ENV.delete(Util::LOG_FILE_ENV)
    ENV.delete(PostDeployWork::DEFER_ENV)
  end

  def filed = PostDeployWork::Filed.new(epic: 900, children: [[901, "Publish platform apibuilder specs"]])

  def post_release(app: "platform", work: FakeWork.new(filed, nil))
    PostRelease.new(app: app, dir: "/code/#{app}", work: work)
  end

  # Quiet mode is what turns Util.step into the one-line stage form; a release
  # under `dev deploy` is always in it by the time this runs.
  def run_quiet(pr)
    out = nil
    Dir.mktmpdir do |dir|
      Util.quiet!(File.join(dir, "post-release.log"))
      out = capture_stdout { pr.run }
    end
    out
  end

  # Swallows the SystemExit Util.exit_with_error raises and records its status in
  # @exit_status, so a test can assert on the stage stream of a release that
  # aborted — which is exactly the case the stage protocol is most at risk in.
  def capture_stdout
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    begin
      yield
    rescue SystemExit => e
      @exit_status = e.status
    end
    buf.string
  ensure
    $stdout = old
  end

  def stages(out)
    out.scan(/^(.+?)\.\.\. (done|failed) \(\d+s\)$/).map { |label, outcome| [label, outcome] }
  end

  def test_a_standalone_release_files_its_post_deploy_work_as_one_stage
    out = run_quiet(post_release)
    assert_equal [["Filing post-deploy work", "done"]], stages(out)
  end

  # Work moving off the critical path must not also move out of sight.
  def test_the_release_names_what_it_filed
    out = run_quiet(post_release)
    assert_includes out, "ISS-900 (epic)"
    assert_includes out, "ISS-901 Publish platform apibuilder specs"
  end

  # The stage protocol: the parent reads a dangling "label... " as "this stage is
  # running now", so nothing may land between a stage's two halves. The report
  # comes after the stage has closed its line.
  def test_nothing_lands_between_a_stage_and_its_completion
    out = run_quiet(post_release)
    assert_match(/\AFiling post-deploy work\.\.\. done \(\d+s\)\n/, out)
  end

  # The deploy files ONE epic for every app it released, and sets the defer
  # variable on the releases it spawns. A release that filed its own too would be
  # five epics for one deploy.
  def test_a_release_under_dev_deploy_files_nothing
    ENV[PostDeployWork::DEFER_ENV] = "1"
    work = FakeWork.new(filed, nil)
    out = run_quiet(post_release(work: work))
    assert_empty stages(out)
    assert_empty out
  end

  # NOT best-effort, inherited from the publish it replaced: a deployed API whose
  # specs did not publish is the drift the hermetic design exists to prevent, and
  # nothing tracking the publish is the same failure one step earlier.
  def test_a_filing_failure_fails_the_release_and_says_what_to_run_by_hand
    work = FakeWork.new(nil, ApiError.new("no AI API token stored"))
    err = capture_stderr { run_quiet(post_release(work: work)) }
    assert_equal 1, @exit_status
    assert_includes err, "no AI API token stored"
    assert_includes err, "api publish"
    assert_includes err, "dev issues reconcile --apply"
  end

  # ...and the stage closes as failed rather than leaving a dangling line the
  # deploy display would read as a stage still in progress.
  def test_the_stage_renders_failed_when_the_filing_fails
    work = FakeWork.new(nil, ApiError.new("boom"))
    out = nil
    capture_stderr { out = run_quiet(post_release(work: work)) }
    assert_equal [["Filing post-deploy work", "failed"]], stages(out)
  end

  # The production call shape. Everything else here injects `work`, so a rename of
  # the arguments bin/release actually passes would otherwise surface only at
  # release time — after the deploy, when the release has already changed
  # production.
  def test_constructs_with_the_arguments_bin_release_passes
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { assert_instance_of PostRelease, PostRelease.new(app: "platform") }
    end
  end

  # A checkout with no .api config owns no specs — every frontend, and every repo
  # that consumes the registry without publishing to it.
  def test_owns_specs_is_false_without_an_api_config
    Dir.mktmpdir { |dir| refute PostRelease.owns_specs?(dir) }
  end

  private

  # Util.exit_with_error writes the recovery hint to stderr on its way out.
  def capture_stderr
    buf = StringIO.new
    old = $stderr
    $stderr = buf
    yield
    buf.string
  ensure
    $stderr = old
  end
end
