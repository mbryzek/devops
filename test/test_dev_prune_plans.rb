#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev prune plans`: the keep/delete policy, the top-level-only scope, and
# the git-log walk that dates each file.
#
# The whole command is safe only because the content it removes stays in git
# history, so the load-bearing cases here are the ones where that is NOT true —
# an untracked file, or a tracked file with uncommitted changes. Those must be
# kept at any age; removing them would be permanent.
class TestDevPrunePlans < Minitest::Test
  # A file's commit time is ~now, so a cutoff in the PAST leaves it "recent" and a
  # cutoff in the FUTURE ages it out.
  RECENT_CUTOFF = Time.now - 3600
  AGED_CUTOFF   = Time.now + 3600

  def git(dir, *args)
    out, status = Open3.capture2("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
    out
  end

  # A repo shaped like ~/code/claude: a plans/ dir with committed files.
  def make_claude_repo(dir, files: { "plans/a.md" => "a" })
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.email", "t@t.com")
    git(dir, "config", "user.name", "t")
    files.each do |path, body|
      FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
      File.write(File.join(dir, path), body)
    end
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", "init")
    dir
  end

  # ================================================================
  # classify_plan_file — the policy, with no repo involved.
  # ================================================================

  def test_aged_and_clean_is_deleted
    action, reason = classify_plan_file(
      "plans/old.md", last_commit_time: Time.now.to_i, dirty: false, cutoff_time: AGED_CUTOFF
    )
    assert_equal :delete, action
    assert_nil reason
  end

  def test_recent_is_kept
    action, reason = classify_plan_file(
      "plans/new.md", last_commit_time: Time.now.to_i, dirty: false, cutoff_time: RECENT_CUTOFF
    )
    assert_equal :keep, action
    assert_match(/within window/, reason)
  end

  # ---- the two cases where "it's in git history" is false ----

  def test_untracked_is_kept_even_when_aged
    # No commit time => the file has never been committed. Deleting it would not
    # be recoverable, so age must not matter.
    action, reason = classify_plan_file(
      "plans/scratch.md", last_commit_time: nil, dirty: true, cutoff_time: AGED_CUTOFF
    )
    assert_equal :keep, action
    assert_match(/not in git history/, reason)
  end

  def test_dirty_is_kept_even_when_aged
    # Committed long ago but edited since: history holds the OLD content, and the
    # working-tree content would be lost.
    action, reason = classify_plan_file(
      "plans/wip.md", last_commit_time: Time.now.to_i, dirty: true, cutoff_time: AGED_CUTOFF
    )
    assert_equal :keep, action
    assert_match(/uncommitted changes/, reason)
  end

  def test_boundary_exactly_at_cutoff_is_kept
    # >= cutoff keeps, so a file committed exactly on the boundary survives.
    now = Time.now
    action, = classify_plan_file(
      "plans/edge.md", last_commit_time: now.to_i, dirty: false, cutoff_time: now
    )
    assert_equal :keep, action
  end

  # ================================================================
  # Scope: top-level files only.
  # ================================================================

  def test_subdirectories_are_never_candidates
    paths = %w[plans/top.md plans/specs/nested.md plans/hoa/deep/nested.md]
    assert_equal ["plans/top.md"], plans_top_level_candidates(paths)
  end

  def test_paths_outside_plans_are_not_candidates
    paths = %w[plans/top.md rules/other.mdc CLAUDE.md]
    assert_equal ["plans/top.md"], plans_top_level_candidates(paths)
  end

  # The candidate universe is the tracked files, NOT the git log. A path a prior
  # prune already removed stays in history forever; sourcing candidates from the
  # log would re-offer all 900 of them on every subsequent run.
  def test_already_pruned_paths_are_not_re_offered
    Dir.mktmpdir do |dir|
      make_claude_repo(dir, files: { "plans/a.md" => "a", "plans/gone.md" => "g" })
      git(dir, "rm", "-q", "plans/gone.md")
      git(dir, "commit", "-qm", "prune")

      assert_includes plans_last_commit_times(dir).keys, "plans/gone.md",
                      "history still records it — which is exactly the trap"
      candidates = plans_top_level_candidates(plans_tracked_files(dir))
      assert_equal ["plans/a.md"], candidates
    end
  end

  def test_tracked_files_excludes_untracked
    Dir.mktmpdir do |dir|
      make_claude_repo(dir)
      File.write(File.join(dir, "plans/untracked.md"), "u")
      refute_includes plans_tracked_files(dir), "plans/untracked.md"
    end
  end

  # `git add` with no commit: in ls-files, so it reaches classification, but its
  # content is in no commit. This is the case the nil-time guard exists for.
  def test_staged_but_never_committed_file_is_tracked_yet_undated
    Dir.mktmpdir do |dir|
      make_claude_repo(dir)
      File.write(File.join(dir, "plans/staged.md"), "s")
      git(dir, "add", "plans/staged.md")

      assert_includes plans_tracked_files(dir), "plans/staged.md"
      assert_nil plans_last_commit_times(dir)["plans/staged.md"]
      action, reason = classify_plan_file(
        "plans/staged.md", last_commit_time: nil, dirty: true, cutoff_time: AGED_CUTOFF
      )
      assert_equal :keep, action
      assert_match(/not in git history/, reason)
    end
  end

  # ================================================================
  # plans_last_commit_times — the git log walk.
  # ================================================================

  def test_last_commit_time_is_the_most_recent_commit_touching_a_file
    Dir.mktmpdir do |dir|
      make_claude_repo(dir, files: { "plans/a.md" => "a", "plans/b.md" => "b" })
      first = plans_last_commit_times(dir)

      sleep 1.1 # commit timestamps are whole seconds
      File.write(File.join(dir, "plans/a.md"), "a2")
      git(dir, "commit", "-qam", "touch a")
      second = plans_last_commit_times(dir)

      assert_operator second["plans/a.md"], :>, first["plans/a.md"], "a was recommitted"
      assert_equal first["plans/b.md"], second["plans/b.md"], "b was not touched"
    end
  end

  def test_untracked_file_has_no_commit_time
    Dir.mktmpdir do |dir|
      make_claude_repo(dir)
      File.write(File.join(dir, "plans/new.md"), "new")
      times = plans_last_commit_times(dir)
      assert_nil times["plans/new.md"]
      refute_nil times["plans/a.md"]
    end
  end

  # ================================================================
  # plans_dirty_paths — what the shared checkout has in flight.
  # ================================================================

  def test_dirty_paths_reports_modified_and_untracked
    Dir.mktmpdir do |dir|
      make_claude_repo(dir, files: { "plans/a.md" => "a", "plans/b.md" => "b" })
      File.write(File.join(dir, "plans/a.md"), "modified")
      File.write(File.join(dir, "plans/untracked.md"), "new")

      dirty = plans_dirty_paths(dir)
      assert_includes dirty, "plans/a.md"
      assert_includes dirty, "plans/untracked.md"
      refute_includes dirty, "plans/b.md", "an unmodified file is not dirty"
    end
  end

  def test_dirty_paths_is_empty_on_a_clean_repo
    Dir.mktmpdir do |dir|
      make_claude_repo(dir)
      assert_empty plans_dirty_paths(dir)
    end
  end

  def test_dirty_paths_ignores_changes_outside_plans
    Dir.mktmpdir do |dir|
      make_claude_repo(dir, files: { "plans/a.md" => "a", "CLAUDE.md" => "c" })
      File.write(File.join(dir, "CLAUDE.md"), "changed")
      assert_empty plans_dirty_paths(dir), "only plans/ is in scope"
    end
  end

  # ================================================================
  # End-to-end policy over a real repo: the pieces wired together.
  # ================================================================

  def test_dirty_aged_file_survives_while_clean_aged_sibling_is_reaped
    Dir.mktmpdir do |dir|
      make_claude_repo(dir, files: {
        "plans/clean.md"    => "c",
        "plans/wip.md"      => "w",
        "plans/specs/x.md"  => "x",
      })
      File.write(File.join(dir, "plans/wip.md"), "edited")
      File.write(File.join(dir, "plans/untracked.md"), "u")

      times = plans_last_commit_times(dir)
      dirty = plans_dirty_paths(dir)
      deleted = plans_top_level_candidates(plans_tracked_files(dir)).select { |p|
        classify_plan_file(
          p, last_commit_time: times[p], dirty: dirty.include?(p), cutoff_time: AGED_CUTOFF
        ).first == :delete
      }

      assert_equal ["plans/clean.md"], deleted
    end
  end

  # ================================================================
  # prune_plans_apply — the worktree + push path, against a local bare remote
  # so no network is touched.
  # ================================================================

  # repo with `origin` pointing at a bare clone, main pushed. Returns [repo, bare].
  def make_repo_with_remote(dir, files:)
    repo = File.join(dir, "claude")
    bare = File.join(dir, "claude.git")
    FileUtils.mkdir_p(repo)
    make_claude_repo(repo, files: files)
    git(dir, "init", "-q", "--bare", bare)
    git(repo, "remote", "add", "origin", bare)
    git(repo, "push", "-q", "-u", "origin", "main")
    [repo, bare]
  end

  # Content of a path on the remote's main, or nil if absent there.
  def remote_file(bare, path)
    # capture3: an absent path is an expected outcome here, so its "fatal:" on
    # stderr is swallowed rather than printed as test noise.
    out, _err, status = Open3.capture3("git", "-C", bare, "show", "main:#{path}")
    status.success? ? out : nil
  end

  def test_apply_removes_from_remote_main_and_leaves_history_recoverable
    Dir.mktmpdir do |dir|
      repo, bare = make_repo_with_remote(dir, files: { "plans/old.md" => "OLD", "plans/keep.md" => "k" })

      assert prune_plans_apply(repo, ["plans/old.md"], 14)

      assert_nil remote_file(bare, "plans/old.md"), "pruned from main"
      assert_equal "k", remote_file(bare, "plans/keep.md"), "untouched file survives"

      # The whole safety claim: the content is still retrievable from history.
      sha, = Open3.capture2("git", "-C", bare, "rev-list", "-n", "1", "main", "--", "plans/old.md")
      parent, = Open3.capture2("git", "-C", bare, "rev-parse", "#{sha.strip}^")
      recovered, status = Open3.capture2("git", "-C", bare, "show", "#{parent.strip}:plans/old.md")
      assert status.success?
      assert_equal "OLD", recovered
    end
  end

  def test_apply_does_not_disturb_the_shared_checkouts_working_tree
    # The reason this uses a worktree at all: ~/code/claude is one checkout shared
    # by concurrent sessions, and a parallel session's in-flight edit must survive.
    Dir.mktmpdir do |dir|
      repo, = make_repo_with_remote(dir, files: { "plans/old.md" => "OLD", "plans/wip.md" => "w" })
      File.write(File.join(repo, "plans/wip.md"), "IN FLIGHT")
      File.write(File.join(repo, "plans/untracked.md"), "SCRATCH")

      assert prune_plans_apply(repo, ["plans/old.md"], 14)

      assert_equal "IN FLIGHT", File.read(File.join(repo, "plans/wip.md")), "uncommitted edit intact"
      assert_equal "SCRATCH", File.read(File.join(repo, "plans/untracked.md")), "untracked file intact"
      refute_empty plans_dirty_paths(repo), "the shared checkout still has its changes staged for the session"
    end
  end

  def test_apply_leaves_no_worktree_behind
    Dir.mktmpdir do |dir|
      repo, = make_repo_with_remote(dir, files: { "plans/old.md" => "OLD" })
      assert prune_plans_apply(repo, ["plans/old.md"], 14)
      out, = Open3.capture2("git", "-C", repo, "worktree", "list")
      assert_equal 1, out.lines.length, "only the main checkout remains: #{out}"
    end
  end

  def test_apply_is_idempotent_when_the_path_is_already_gone_on_main
    # --ignore-unmatch: another session's prune may have landed first. That is a
    # no-op, not a failure.
    Dir.mktmpdir do |dir|
      repo, = make_repo_with_remote(dir, files: { "plans/old.md" => "OLD" })
      assert prune_plans_apply(repo, ["plans/old.md"], 14)
      assert prune_plans_apply(repo, ["plans/old.md"], 14), "second run must succeed"
    end
  end

  # ================================================================
  # Arg handling.
  # ================================================================

  def test_negative_days_is_rejected
    out, status = capture_stderr_and_exit { cmd_prune_plans(["--days", "-1"]) }
    assert_equal 1, status
    assert_match(/--days must be >= 0/, out)
    assert_match(/dev prune plans/, out)
  end

  def test_non_integer_days_is_rejected
    out, status = capture_stderr_and_exit { cmd_prune_plans(["--days", "soon"]) }
    assert_equal 1, status
    assert_match(/--days must be an integer/, out)
  end

  def test_unknown_flag_is_rejected
    out, status = capture_stderr_and_exit { cmd_prune_plans(["--force"]) }
    assert_equal 1, status
    assert_match(/Unknown flag: --force/, out)
  end

  def test_prune_is_a_known_command_with_subcommands
    assert_includes COMMANDS, "prune"
    assert_equal %w[plans], SUBCOMMANDS["prune"]
    assert INVOCATIONS.key?("prune plans"), "usage line must exist for usage_for"
  end

  def test_bare_prune_names_its_subcommand
    out, status = capture_stderr_and_exit { require_subcommand("prune") }
    assert_equal 1, status
    assert_match(/prune requires a subcommand \(plans\)/, out)
  end

  include DevTestSupport
end
