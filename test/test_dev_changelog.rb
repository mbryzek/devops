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
class TestChangelogSnapshotUnchangedReason < Minitest::Test
  def test_explains_a_build_of_only_empty_notes
    assert_includes changelog_snapshot_unchanged_reason(0, 2), "all 2 new note(s) had no user-facing changes"
  end

  def test_stays_silent_when_something_was_published
    assert_equal "", changelog_snapshot_unchanged_reason(1, 2)
  end

  def test_stays_silent_when_nothing_was_built_at_all
    assert_equal "", changelog_snapshot_unchanged_reason(0, 0)
  end
end

class TestChangelogNotesEntryCount < Minitest::Test
  def with_notes(contents)
    Dir.mktmpdir("notes") do |dir|
      f = File.join(dir, "n.json")
      File.write(f, contents)
      yield f
    end
  end

  def test_counts_entries
    with_notes(JSON.generate("entries" => [1, 2])) { |f| assert_equal 2, changelog_notes_entry_count(f) }
  end

  # Unreadable or malformed notes must not crash the summary; they just publish nothing.
  def test_unreadable_notes_count_as_zero
    with_notes("not json") { |f| assert_equal 0, changelog_notes_entry_count(f) }
    assert_equal 0, changelog_notes_entry_count("/nonexistent/n.json")
  end
end

# Exercises the real cmd_changelog_build against a temp data lake, with only the
# outside world (Claude, git, ISS lookup, admin snapshot) stubbed. Asserts the thing
# that matters: one Claude session per BATCH, not per version.
class TestDevChangelogBuild < Minitest::Test
  APPS = %w[playbook-admin].freeze

  def setup
    @repo = Dir.mktmpdir("changelog-lake")
    @inputs = []
    @pushed = []
    @snapshots = []
    @entries_by_version = {}
    stub_world!
  end

  def teardown
    FileUtils.remove_entry(@repo)
    # Unlike the other stubs, this one shadows a method other tests assert on, so put
    # the real implementation back rather than leaking it across the suite.
    Object.send(:define_method, :changelog_app_repo, @real_app_repo)
  end

  def write_tag(version, released_at, commits)
    dir = File.join(@repo, "playbook-admin")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{version}.tag.json"),
               JSON.generate("application" => "playbook-admin", "version" => version,
                             "released_at" => released_at, "commits" => commits))
  end

  def notes(version)
    f = File.join(@repo, "playbook-admin", "#{version}.notes.json")
    File.exist?(f) ? JSON.parse(File.read(f)) : nil
  end

  # Replace every boundary cmd_changelog_build crosses. `changelog_run_claude`
  # records the payload it was handed and writes the notes files a real session
  # would, so the caller's validation still runs for real.
  def stub_world!
    repo = @repo
    inputs = @inputs
    pushed = @pushed
    Object.send(:define_method, :ensure_changelog_repo!) { repo }
    # The ISS map is keyed by repo slug, the app is playbook-admin: the build has to
    # bridge the two, so pin the mapping rather than depending on a generated dist/.
    Object.send(:define_method, :changelog_issue_map) { |_localhost| { "legacy-admin#412" => "034" } }
    @real_app_repo = Object.instance_method(:changelog_app_repo)
    Object.send(:define_method, :changelog_app_repo) { |_app| "legacy-admin" }
    snapshots = @snapshots
    Object.send(:define_method, :changelog_refresh_admin_snapshot!) { |_r, **kw| snapshots << kw }
    Object.send(:define_method, :changelog_git_commit_push!) { |_dir, message| pushed << message }
    entries_by_version = @entries_by_version
    Object.send(:define_method, :changelog_run_claude) do |_r, input_path, version_count|
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

  def test_all_pending_versions_go_to_one_session
    3.times { |i| write_tag("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00", []) }
    build
    assert_equal 1, @inputs.length
    assert_equal %w[0.3.2 0.3.1 0.3.0], @inputs[0]["versions"].map { |v| v["version"] }
    assert_equal 1, @pushed.length
    3.times { |i| refute_nil notes("0.3.#{i}") }
  end

  # The header names the batch; the versions in it are listed one per line with the
  # commit load that made the batch that size.
  def test_batch_header_lists_each_version_and_its_commit_count
    write_tag("0.3.0", "2026-07-20T14:00:00-04:00", [{ "sha" => "a", "subject" => "s" }])
    out = build
    assert_includes out, "changelog build [batch 1/1]: 1 version(s) via Claude (#{CHANGELOG_CLAUDE_MODEL})\n"
    assert_includes out, "  playbook-admin/0.3.0  1 commit(s)"
  end

  def test_batch_size_splits_into_multiple_sessions
    5.times { |i| write_tag("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00", []) }
    build("--batch-size", "2")
    assert_equal [2, 2, 1], @inputs.map { |i| i["versions"].length }
    assert_equal %w[0.3.4 0.3.3 0.3.2 0.3.1 0.3.0],
                 @inputs.flat_map { |i| i["versions"].map { |v| v["version"] } }
  end

  # End-to-end version of the commit bound: a fat version is not batched with others.
  def test_commit_heavy_version_gets_its_own_session
    write_tag("0.0.1", "2026-07-01T14:00:00-04:00",
              Array.new(CHANGELOG_BUILD_BATCH_COMMITS + 1) do |i|
                { "sha" => "s#{i}", "subject" => "c#{i}", "body" => "", "pr_number" => nil }
              end)
    write_tag("0.0.2", "2026-07-02T14:00:00-04:00", [])
    build
    assert_equal [%w[0.0.2], %w[0.0.1]], @inputs.map { |i| i["versions"].map { |v| v["version"] } }
  end

  # The page links PRs off the repo, which is not the app name, so the CLI stamps it
  # deterministically after the session rather than trusting the model to echo it.
  def test_notes_are_stamped_with_the_repo
    write_tag("0.3.0", "2026-07-20T14:00:00-04:00", [])
    build
    assert_equal "legacy-admin", notes("0.3.0")["repo"]
  end

  def test_input_payload_carries_commits_and_resolved_issue
    write_tag("0.3.0", "2026-07-20T14:00:00-04:00",
              [{ "sha" => "abc", "subject" => "Add changelog page (#412)", "body" => "b", "pr_number" => 412 },
               { "sha" => "def", "subject" => "Bump version", "body" => "", "pr_number" => nil }])
    build
    v = @inputs[0]["versions"][0]
    assert_equal "playbook-admin", v["application"]
    assert_equal "0.3.0", v["version"]
    assert_equal File.join(@repo, "playbook-admin", "0.3.0.notes.json"), v["notes_file"]
    assert_equal "034", v["commits"][0]["issue_number"]
    assert_nil v["commits"][1]["issue_number"]
  end

  # Versions already carrying notes are never re-evaluated, so a re-run after a
  # partially failed batch only asks about what is still missing.
  def test_existing_notes_are_skipped
    2.times { |i| write_tag("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00", []) }
    File.write(File.join(@repo, "playbook-admin", "0.3.0.notes.json"),
               JSON.generate("application" => "playbook-admin", "version" => "0.3.0", "entries" => []))
    build
    assert_equal %w[0.3.1], @inputs[0]["versions"].map { |v| v["version"] }
  end

  # A release whose commits were all judged uninteresting still gets a notes file, but
  # /admin/changelog never shows it. The summary has to separate the two so a build that
  # produced nothing visible does not read as a build that published something.
  def test_summary_separates_published_notes_from_empty_ones
    2.times { |i| write_tag("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00", []) }
    @entries_by_version["0.3.1"] = [{ "title" => "Something", "description" => "d" }]
    out = build
    assert_includes out, "wrote 2 notes file(s): 1 with release notes, 1 with no user-facing changes"
    assert_includes out, "  playbook-admin/0.3.0  no user-facing changes"
    assert_includes out, "  playbook-admin/0.3.1  1 note(s)"
    assert_equal [{ published: 1, empty: 1 }], @snapshots
  end

  # A session that returns without writing a file must not be reported as built —
  # only the versions whose files exist are committed, the rest fail the command.
  def test_versions_left_unwritten_fail_the_command
    2.times { |i| write_tag("0.3.#{i}", "2026-07-#{20 + i}T14:00:00-04:00", []) }
    Object.send(:define_method, :changelog_run_claude) { |_r, _input_path, _count| "claude timed out" }
    assert_raises(SystemExit) { build }
    assert_empty @pushed
  end
end

# The snapshot PR is merged for Mike, so the merge itself has to survive GitHub's
# asynchronous mergeability computation without a human noticing.
class TestChangelogMergeAdminPr < Minitest::Test
  Status = Struct.new(:success?)

  def setup
    @calls = []
    @slept = []
    slept = @slept
    Object.send(:define_method, :sleep) { |secs| slept << secs }
  end

  def teardown
    Object.send(:remove_method, :sleep)
    Open3.singleton_class.send(:remove_method, :capture2e)
  end

  # Each element of `results` is the success? of one `gh pr merge` attempt.
  def stub_merge!(*results)
    calls = @calls
    queue = results.dup
    Open3.define_singleton_method(:capture2e) do |*cmd|
      calls << cmd
      ok = queue.shift
      [ok ? "Merged\n" : "not mergeable\n", Status.new(ok)]
    end
  end

  def merge(number)
    out, err = capture_io { changelog_merge_admin_pr!(number) }
    [out, err]
  end

  def test_merges_the_pr
    stub_merge!(true)
    out, = merge(654)
    assert_includes out, "merged the /admin/changelog snapshot PR #654"
    assert_equal 1, @calls.length
    assert_includes @calls[0], "--squash"
    assert_includes @calls[0], "654"
    assert_empty @slept
  end

  # GitHub reports a freshly opened PR as not mergeable until it finishes computing:
  # retrying, not failing, is what keeps the automation hands-off.
  def test_retries_until_github_reports_mergeable
    stub_merge!(false, false, true)
    out, = merge(654)
    assert_includes out, "merged the /admin/changelog snapshot PR #654"
    assert_equal 3, @calls.length
    assert_equal [CHANGELOG_MERGE_RETRY_SECS] * 2, @slept
  end

  # Best-effort: a PR that will not merge is reported for a human, never raised — the
  # notes are already committed to the lake by this point.
  def test_gives_up_with_a_warning
    stub_merge!(*Array.new(CHANGELOG_MERGE_ATTEMPTS, false))
    _, err = merge(654)
    assert_equal CHANGELOG_MERGE_ATTEMPTS, @calls.length
    assert_equal CHANGELOG_MERGE_ATTEMPTS - 1, @slept.length
    assert_includes err, "could not merge"
    assert_includes err, "#654 (not mergeable)"
  end

  # Nothing to merge when the PR could not be opened.
  def test_no_pr_number_is_a_no_op
    stub_merge!
    out, err = merge(nil)
    assert_empty @calls
    assert_equal "", out
    assert_equal "", err
  end
end

# The PR number is what the merge step acts on, so an empty list has to come back as
# nil rather than as a truthy blob of JSON.
class TestChangelogAdminOpenPrNumber < Minitest::Test
  def stub_gh!(output)
    IO.define_singleton_method(:popen) { |*_args, **_kw| output }
  end

  def teardown
    IO.singleton_class.send(:remove_method, :popen)
  end

  def test_returns_the_open_pr_number
    stub_gh!(JSON.generate([{ "number" => 654 }]))
    assert_equal 654, changelog_admin_open_pr_number
  end

  def test_no_open_pr
    stub_gh!("[]")
    assert_nil changelog_admin_open_pr_number
  end

  # gh failing (not authenticated, no network) prints nothing parseable; that must
  # read as "no PR", not crash the best-effort snapshot path.
  def test_unparseable_gh_output
    stub_gh!("")
    assert_nil changelog_admin_open_pr_number
  end
end
