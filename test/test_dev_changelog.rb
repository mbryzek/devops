#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
load File.expand_path('../bin/dev', __dir__)

class TestDevChangelogFlags < Minitest::Test
  include DevTestSupport

  def test_defaults
    f = changelog_parse_flags([])
    assert_equal CHANGELOG_APPS, f[:apps]
    assert_nil f[:limit]
    assert_nil f[:batch_size]
    refute f[:use_localhost]
  end

  def test_batch_size
    assert_equal 3, changelog_parse_flags(%w[--batch-size 3])[:batch_size]
  end

  def test_batch_size_rejects_non_positive
    [%w[--batch-size 0], %w[--batch-size x], %w[--batch-size]].each do |args|
      err, status = capture_stderr_and_exit { changelog_parse_flags(args) }
      refute_nil status, "expected #{args.inspect} to exit"
      assert_includes err, "--batch-size requires a positive integer"
    end
  end
end

class TestDevChangelogBatches < Minitest::Test
  def v(version, commits) = { version: version, commit_count: commits }

  def versions(batches) = batches.map { |b| b.map { |p| p[:version] } }

  def test_groups_up_to_batch_size
    assert_equal [%w[a b], %w[c]],
                 versions(changelog_batches([v("a", 1), v("b", 1), v("c", 1)], 2))
  end

  def test_closes_a_batch_on_the_commit_bound
    batches = changelog_batches([v("a", 60), v("b", 60), v("c", 1)], 10)
    assert_equal [%w[a], %w[b c]], versions(batches)
  end

  # The first tag of an app carries its whole history; it must still be built, alone.
  def test_oversized_version_travels_alone
    batches = changelog_batches([v("big", 517), v("a", 1)], 10)
    assert_equal [%w[big], %w[a]], versions(batches)
  end

  def test_empty
    assert_empty changelog_batches([], 10)
  end
end

class TestDevChangelogTimeout < Minitest::Test
  # A single version keeps the budget it had before batching; a batch scales up but
  # is capped so a wedged session cannot hang the CLI indefinitely.
  def test_scales_between_floor_and_ceiling
    assert_equal 20 * 60, changelog_claude_timeout_secs(1)
    assert_equal 50 * 60, changelog_claude_timeout_secs(10)
    assert_equal 60 * 60, changelog_claude_timeout_secs(100)
  end
end

# The build session runs in a scratch dir, so it can only reach the skill by absolute
# path. When the prompt named it relatively the model found nothing at the cwd and fell
# back to scanning the filesystem for it on every batch.
class TestDevChangelogSkillPath < Minitest::Test
  # Run changelog_run_claude with the subprocess replaced, and return what it would
  # have handed `claude`: [prompt, spawn options].
  def spawn_args(workdir: "/tmp/scratch")
    captured = nil
    done = Object.new
    def done.pid = 4242
    def done.value = nil
    Open3.stub(:popen2e, lambda { |*args, **opts|
      captured = [args.last, opts]
      [StringIO.new, StringIO.new("done"), done]
    }) do
      changelog_run_claude(workdir, "/tmp/scratch/_build_input.json", 3)
    end
    captured
  end

  def test_prompt_names_the_skill_by_absolute_path
    prompt, = spawn_args
    assert_includes prompt, CHANGELOG_SKILL_PATH
    refute_match %r{(?<!/)\.claude/skills}, prompt,
                 "the skill must be named by absolute path, never relative to the cwd"
  end

  # The path is only useful if something is actually there — this is what breaks if the
  # skill is moved or dropped from the repo again.
  def test_the_skill_ships_with_the_cli
    assert File.exist?(CHANGELOG_SKILL_PATH), "no changelog-build skill at #{CHANGELOG_SKILL_PATH}"
  end

  def test_session_runs_in_the_scratch_dir
    _, opts = spawn_args(workdir: "/tmp/some-scratch")
    assert_equal "/tmp/some-scratch", opts[:chdir]
  end
end

# changelog_app_repo maps a deployable to its GitHub repo (the checkout directory).
# It must degrade to the app name rather than raise when the app is not configured —
# `dev changelog` is best-effort and never fails a release.
class TestChangelogAppRepo < Minitest::Test
  def with_apps(apps)
    orig = Config.method(:all)
    Config.define_singleton_method(:all) { apps }
    yield
  ensure
    Config.define_singleton_method(:all, orig)
  end

  def setup
    # changelog_app_repo memoizes per process; clear it between cases.
    Object.send(:remove_instance_variable, :@changelog_app_repos) if Object.instance_variable_defined?(:@changelog_app_repos)
  end

  def test_resolves_an_app_to_its_repo
    app = App.new("name" => "playbook-www", "port" => 80, "repo" => "mbryzek/legacy-www")
    with_apps([app]) { assert_equal "legacy-www", changelog_app_repo("playbook-www") }
  end

  def test_unconfigured_app_keeps_its_name
    with_apps([]) { assert_equal "rallyd", changelog_app_repo("rallyd") }
  end

  def test_a_config_failure_is_not_fatal
    orig = Config.method(:all)
    Config.define_singleton_method(:all) { raise "no env checkout" }
    assert_equal "rallyd", changelog_app_repo("rallyd")
  ensure
    Config.define_singleton_method(:all, orig)
  end
end

# The capture summary is the only place that reports which checkouts were read, so a
# missing checkout or a renamed repo has to be visible in it.
class TestChangelogCaptureScanLine < Minitest::Test
  def test_reports_tag_counts_and_the_latest_tag
    line = changelog_capture_scan_line(app: "playbook-www", repo: "playbook-www",
                                       tags: 41, new: 1, latest: "0.0.41")
    assert_equal "  playbook-www: 41 tag(s), 1 new, latest 0.0.41", line
  end

  def test_names_the_repo_when_it_differs_from_the_app
    line = changelog_capture_scan_line(app: "playbook-www", repo: "legacy-www",
                                       tags: 0, new: 0, latest: nil)
    assert_equal "  playbook-www (legacy-www): 0 tag(s), 0 new, latest (none)", line
  end

  def test_a_skipped_app_says_why
    line = changelog_capture_scan_line(app: "playbook-app", repo: "playbook-app",
                                       skipped: "skipped, no checkout at /x")
    assert_equal "  playbook-app: skipped, no checkout at /x", line
  end
end

# A build lists every version it touched on its own line; the labels are padded so the
# details line up, which is the whole point of not comma-joining them.
class TestChangelogBuildLines < Minitest::Test
  def test_pads_labels_to_a_common_width
    lines = changelog_build_lines([{ app: "playbook-app", version: "0.1.71", commit_count: 12 },
                                   { app: "playbook-admin", version: "0.3.9", commit_count: 3 }]) do |p|
      "#{p[:commit_count]} commit(s)"
    end
    assert_equal ["  playbook-app/0.1.71   12 commit(s)",
                  "  playbook-admin/0.3.9  3 commit(s)"], lines
  end

  def test_empty
    assert_empty changelog_build_lines([]) { "x" }
  end
end

# "snapshot already current" right after a successful build looks like a bug unless the
# build's own output explains that the new notes had nothing to show.
# Exercises the real cmd_changelog_build with only the outside world stubbed -- the
# API, Claude, git and the ISS lookup. Asserts the things that matter: one Claude
# session per BATCH rather than per version, and that every evaluated version is
# reported to the API including the ones the model found nothing to say about.
class TestDevChangelogBuild < Minitest::Test
  def setup
    # changelog_pending skips an app with no checkout, so the fake one has to look
    # like a git repo even though every git read below is stubbed.
    @checkout = Dir.mktmpdir("changelog-checkout")
    FileUtils.mkdir_p(File.join(@checkout, ".git"))
    @inputs = []
    @posted = []
    @missing = %w[]
    @entries_by_version = {}
    @commits_by_version = Hash.new { [] }
    @real_methods = {}
    stub_world!
  end

  def teardown
    FileUtils.remove_entry(@checkout)
    # Every stub lands on Object, so one left behind is visible to every later test in
    # the process, not just this class — restore them all.
    @real_methods.each { |name, m| Object.send(:define_method, name, m) }
  end

  # Replace a global for the duration of one test, remembering the real one so teardown
  # can put it back.
  def stub_global(name, &body)
    @real_methods[name] ||= begin
      Object.instance_method(name)
    rescue NameError
      nil
    end
    Object.send(:define_method, name, body)
  end

  def pending_version(version, released_at, commits = [])
    @missing << version
    @commits_by_version[version] = commits
    @released_at ||= {}
    @released_at[version] = released_at
  end

  # Replace every boundary cmd_changelog_build crosses. `changelog_run_claude` records
  # the payload it was handed and writes the notes files a real session would, so the
  # caller's validation still runs for real.
  def stub_world!
    inputs = @inputs
    posted = @posted
    missing = @missing
    commits_by_version = @commits_by_version
    entries_by_version = @entries_by_version

    stub_global(:platform_endpoint) { |_localhost| { name: "test" } }
    # The ISS map is keyed by repo slug, the app is playbook-admin: the build has to
    # bridge the two, so pin the mapping rather than depending on a generated dist/.
    stub_global(:changelog_issue_map) { |_localhost| { "legacy-admin#412" => "034" } }
    stub_global(:changelog_app_repo) { |_app| "legacy-admin" }

    # The server's answer to "what still needs notes", plus the git reads the build
    # makes to rebuild each pending version's commit list.
    released_at = -> (v) { (@released_at || {}).fetch(v, "2026-07-20T14:00:00-04:00") }
    stub_global(:changelog_status) do |_endpoint|
      { "playbook-admin" => { "application" => "playbook-admin", "max_version" => missing.last,
                              "versions_missing_notes" => missing.dup } }
    end
    stub_global(:changelog_tags) { |_checkout| missing.dup }
    stub_global(:changelog_commits) { |_checkout, range| commits_by_version[range.split("..").last] }
    stub_global(:changelog_git_out) do |*cmd|
      cmd.include?("--format=%cI") ? released_at.call(cmd.last) : ""
    end
    checkout = @checkout
    stub_global(:changelog_app_checkout) { |_app| checkout }

    stub_global(:changelog_post_batches) do |_endpoint, path, _key, records|
      posted << [path, records]
      records.length
    end

    stub_global(:changelog_run_claude) do |_workdir, input_path, version_count|
      input = JSON.parse(File.read(input_path))
      inputs << input
      raise "version_count disagrees with the payload" unless version_count == input["versions"].length
      input["versions"].each do |v|
        File.write(v["notes_file"], JSON.generate(
          "application" => v["application"], "version" => v["version"],
          "released_at" => v["released_at"], "entries" => entries_by_version.fetch(v["version"], [])
        ))
      end
      ""
    end
  end

  def build(*args)
    out, = capture_io { cmd_changelog_build(["--app", "playbook-admin"] + args) }
    out
  end

  def posted_notes
    @posted.select { |path, _| path == "notes" }.flat_map { |_, records| records }
  end

  def test_all_pending_versions_go_to_one_session
    3.times { |i| pending_version("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00") }
    build
    assert_equal 1, @inputs.length
    assert_equal %w[0.3.2 0.3.1 0.3.0], @inputs[0]["versions"].map { |v| v["version"] }
    assert_equal %w[0.3.2 0.3.1 0.3.0], posted_notes.map { |n| n["version"] }
  end

  def test_batch_header_lists_each_version_and_its_commit_count
    pending_version("0.3.0", "2026-07-20T14:00:00-04:00", [{ "sha" => "a", "subject" => "s" }])
    out = build
    assert_includes out, "changelog build [batch 1/1]: 1 version(s) via Claude (#{CHANGELOG_CLAUDE_MODEL})\n"
    assert_includes out, "  playbook-admin/0.3.0  1 commit(s)"
  end

  def test_batch_size_splits_into_multiple_sessions
    5.times { |i| pending_version("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00") }
    build("--batch-size", "2")
    assert_equal [2, 2, 1], @inputs.map { |i| i["versions"].length }
    assert_equal %w[0.3.4 0.3.3 0.3.2 0.3.1 0.3.0],
                 @inputs.flat_map { |i| i["versions"].map { |v| v["version"] } }
  end

  def test_input_payload_carries_commits_and_resolved_issue
    pending_version("0.3.0", "2026-07-20T14:00:00-04:00",
                    [{ "sha" => "abc", "subject" => "Add changelog page (#412)", "body" => "b", "pr_number" => 412 },
                     { "sha" => "def", "subject" => "Bump version", "pr_number" => nil }])
    build
    v = @inputs[0]["versions"][0]
    assert_equal "playbook-admin", v["application"]
    assert_equal "0.3.0", v["version"]
    assert_equal "034", v["commits"][0]["issue_number"]
    assert_nil v["commits"][1]["issue_number"]
  end

  # The property notes_built_at exists for. A release the model found nothing to say
  # about still has to be REPORTED, with an empty entries list -- that is what marks it
  # evaluated. Reporting only the ones with entries would leave it pending forever, and
  # it would be sent back to the model on every build.
  def test_a_version_with_no_entries_is_still_reported
    2.times { |i| pending_version("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00") }
    @entries_by_version["0.3.1"] = [{ "summary" => "Something", "category" => "fix" }]
    out = build
    assert_equal %w[0.3.1 0.3.0], posted_notes.map { |n| n["version"] }.sort.reverse
    assert_empty posted_notes.find { |n| n["version"] == "0.3.0" }["entries"]
    assert_includes out, "recorded notes for 2 version(s): 1 with release notes, 1 with no user-facing changes"
  end

  # A session that returns without writing a file must not be reported as built.
  def test_versions_left_unwritten_fail_the_command
    2.times { |i| pending_version("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00") }
    stub_global(:changelog_run_claude) { |_w, _input_path, _count| "claude timed out" }
    assert_raises(SystemExit) { build }
    assert_empty posted_notes
  end

  def test_nothing_pending_is_a_no_op
    out = build
    assert_includes out, "nothing to build"
    assert_empty @posted
  end
end
