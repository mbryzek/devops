#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev ai prune`'s classification: which ~/code/ai feature dirs are safe to
# delete. The rule is "keep unless proven disposable" — a dir is deleted only when
# every real git repo inside is clean AND either fully pushed or its branch's PR is
# merged/closed. A merged/closed PR OVERRIDES recency (landed work is deleted even
# if touched today); recency only shields dirs with no merged PR and nothing local
# at risk. Uncommitted changes and local-only commits with no merged/closed PR
# always protect a dir. gh is stubbed via the injected pr_state so no network is
# touched; git state is exercised against real temp repos.
class TestDevAidirs < Minitest::Test
  # cutoff far in the future => every temp dir counts as "modified within cutoff",
  # so pass PAST to reach the git checks and FUTURE to assert the recency guard.
  PAST   = Time.now - 3600
  FUTURE = Time.now + 3600
  NO_PR  = ->(_slug, _branch) { nil }

  # pr_state stub: return the {state:, number:} shape gh_pr_state produces.
  def self.pr(state, number = 1) = ->(_slug, _branch) { { state: state, number: number } }
  MERGED = pr(:merged)
  CLOSED = pr(:closed)
  OPEN   = pr(:open, 7)

  def git(dir, *args)
    out, status = Open3.capture2("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
    out
  end

  # A repo with one commit and (by default) no remote — so its commit is local-only.
  def make_repo(parent, name, remote: false)
    repo = File.join(parent, name)
    FileUtils.mkdir_p(repo)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "t@t.com")
    git(repo, "config", "user.name", "t")
    File.write(File.join(repo, "f.txt"), "hi")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "init")
    push_to_bare_remote(parent, repo) if remote
    repo
  end

  # Give a repo an origin whose main already contains HEAD, so nothing is
  # local-only. No real remote needed — a remote-tracking ref at HEAD is enough to
  # make `git log --not --remotes` empty (and avoids polluting the feature dir with
  # a bare mirror, which the loose-content guard would rightly flag).
  def push_to_bare_remote(_parent, repo)
    git(repo, "remote", "add", "origin", "git@github.com:mbryzek/#{File.basename(repo)}.git")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
  end

  # ---- clean + pushed => delete, and gh is never consulted ----

  def test_clean_and_pushed_is_deletable_without_pr_check
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true)
      called = false
      pr = ->(_s, _b) { called = true; :open }
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: pr)
      assert_equal :delete, action
      refute called, "gh should not be consulted when nothing is local-only"
    end
  end

  # ---- local-only commits gated on PR state ----

  def test_local_only_commits_with_merged_pr_is_deletable
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: MERGED)
      assert_equal :delete, action
    end
  end

  def test_local_only_commits_with_closed_pr_is_deletable
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: CLOSED)
      assert_equal :delete, action
    end
  end

  def test_local_only_commits_with_open_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: OPEN)
      assert_equal :keep, action
      assert_match(/local-only commits.*platform#7 OPEN/, reason)
    end
  end

  def test_local_only_commits_with_no_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/no PR/, reason)
    end
  end

  # ---- uncommitted changes always win ----

  def test_uncommitted_changes_kept_even_when_merged
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      File.write(File.join(repo, "f.txt"), "dirty")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: MERGED)
      assert_equal :keep, action
      assert_match(/uncommitted changes/, reason)
    end
  end

  # ---- recency guard ----
  #
  # A merged/closed PR is proof the work landed, so it deletes the dir even when
  # it was touched today. Recency only shields dirs we can't prove are finished:
  # nothing local at risk and no merged PR to point at.

  def test_recent_dir_with_merged_pr_is_deleted
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only commit, but its PR merged
      # PAST cutoff => dir is "recent"; the merged PR must still win.
      action, = classify_ai_dir(dir, cutoff_time: PAST, pr_state: MERGED)
      assert_equal :delete, action
    end
  end

  def test_recent_clean_pushed_dir_is_kept_by_recency
    Dir.mktmpdir do |dir|
      # Fully pushed, nothing local at risk, no merged PR — a fresh clone still on
      # main. Nothing proves it's finished, so recency keeps it and gh is never hit.
      make_repo(dir, "platform", remote: true)
      pr = ->(_s, _b) { flunk "no local-only commits => PR must not be consulted" }
      action, reason = classify_ai_dir(dir, cutoff_time: PAST, pr_state: pr)
      assert_equal :keep, action
      assert_equal "modified within cutoff", reason
    end
  end

  def test_recent_dir_with_open_pr_is_kept_as_unsaved
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only commit, PR still open
      action, reason = classify_ai_dir(dir, cutoff_time: PAST, pr_state: OPEN)
      assert_equal :keep, action
      assert_match(/local-only commits.*platform#7 OPEN/, reason)
    end
  end

  # ---- empty / symlink-only dirs ----

  def test_empty_dir_is_deletable
    Dir.mktmpdir do |dir|
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  def test_symlink_only_dir_is_deletable
    Dir.mktmpdir do |dir|
      File.symlink("/tmp", File.join(dir, "devops"))
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :delete, action, "a dir holding only symlinks loses nothing on delete"
    end
  end

  # ---- multi-repo dir: unsafe if ANY repo is unsafe ----

  def test_multi_repo_kept_when_one_repo_unsafe
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # safe
      make_repo(dir, "platform")                # local-only, no PR => unsafe
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/platform/, reason)
    end
  end

  # ---- symlinked repo is ignored (deleting the link is harmless) ----

  def test_symlinked_repo_subdir_is_ignored
    Dir.mktmpdir do |dir|
      real = make_repo(Dir.mktmpdir, "shared") # dirty real repo elsewhere
      File.write(File.join(real, "f.txt"), "dirty")
      File.symlink(real, File.join(dir, "devops"))
      # only a symlink inside => effectively empty => deletable, real repo untouched
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  # ---- safety guards: unsaved work that isn't a plain dirty tree ----

  def test_detached_head_is_kept
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      # a commit made while detached hangs off no branch ref
      git(repo, "checkout", "-q", "--detach")
      File.write(File.join(repo, "f.txt"), "more")
      git(repo, "commit", "-qam", "detached work")
      # gh must never even be consulted — the detached guard fires first
      pr = ->(_s, _b) { flunk "detached repo must be kept before any PR check" }
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: pr)
      assert_equal :keep, action
      assert_match(/detached HEAD/, reason)
    end
  end

  def test_stashed_changes_are_kept
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform", remote: true) # clean + pushed otherwise
      File.write(File.join(repo, "f.txt"), "wip")
      git(repo, "stash", "push", "-q")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/stashed changes/, reason)
    end
  end

  def test_loose_nonrepo_content_beside_a_repo_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # clean + pushed
      FileUtils.mkdir_p(File.join(dir, "notes"))
      File.write(File.join(dir, "notes", "findings.md"), "irreplaceable")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/non-repo content/, reason)
    end
  end

  def test_top_level_clone_with_tracked_files_is_not_flagged_as_loose
    Dir.mktmpdir do |parent|
      # repo cloned AT the feature-dir top level: its own files are git-tracked,
      # so git_clean? covers them and they must not read as "loose content".
      dir = make_repo(parent, "feature", remote: true)
      refute ai_dir_has_loose_content?(dir, ai_dir_repos(dir))
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  def test_gh_pr_state_missing_binary_degrades_to_nil
    # Simulate `gh` absent by emptying PATH; the lookup must return nil (keep),
    # not raise Errno::ENOENT mid-scan.
    old = ENV["PATH"]
    ENV["PATH"] = ""
    assert_nil gh_pr_state("mbryzek/platform", "some-branch")
  ensure
    ENV["PATH"] = old
  end

  # ---- PR tie surfaced in output ----

  def test_merged_pr_number_and_state_surface_in_notes
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only commit
      action, _reason, notes = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: TestDevAidirs.pr(:merged, 1204))
      assert_equal :delete, action
      assert_equal ["platform#1204 MERGED"], notes
    end
  end

  def test_cleanly_pushed_dir_has_no_pr_notes
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # no local-only commits => no gh call
      action, _reason, notes = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :delete, action
      assert_empty notes
    end
  end

  # ---- helpers ----

  def test_git_slug_parses_ssh_and_https
    assert_equal "mbryzek/devops", git_slug_from("git@github.com:mbryzek/devops.git")
    assert_equal "mbryzek/devops", git_slug_from("https://github.com/mbryzek/devops")
    assert_nil git_slug_from("/local/path/no-remote")
  end

  # git_slug reads from a repo; exercise the url regex directly via a temp repo.
  def git_slug_from(url)
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      git(dir, "remote", "add", "origin", url) unless url.start_with?("/")
      return git_slug(dir)
    end
  end
end
