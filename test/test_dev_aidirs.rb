#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev aidirs prune`'s classification of ~/code/ai feature dirs into
# :keep / :delete / :trash. Feature dirs are throwaway clones, so the posture is
# aggressive: a dir idle past the cutoff is reaped whatever its git state — clean/
# pushed dirs are hard-:delete'd, dirs holding work not on a remote (uncommitted,
# stashed, detached, loose files, or local-only commits) are :trash'd so they stay
# recoverable. A RECENT dir (touched within the cutoff) keeps the full protection:
# any at-risk state :keep's it, and gh is consulted so a merged/closed PR still lets
# a recent, landed dir be deleted. gh is ONLY consulted for recent dirs. gh is
# stubbed via the injected pr_state so no network is touched; git state is exercised
# against real temp repos.
class TestDevAidirs < Minitest::Test
  # recent = last_activity >= cutoff_time. A temp repo's activity is ~now, so a
  # cutoff in the PAST makes the dir "recent" (within the window) and a cutoff in
  # the FUTURE makes it "aged out" (past the window).
  RECENT_CUTOFF = Time.now - 3600
  AGED_CUTOFF   = Time.now + 3600
  NO_PR         = ->(_slug, _branch) { nil }

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

  # ================================================================
  # AGED OUT (cutoff in the future): reap regardless of git state.
  # gh is never consulted.
  # ================================================================

  # ---- clean + pushed => hard delete, gh never consulted ----

  def test_aged_clean_and_pushed_is_hard_deleted_without_pr_check
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true)
      pr = ->(_s, _b) { flunk "aged-out dirs must never consult gh" }
      action, = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: pr)
      assert_equal :delete, action
    end
  end

  # ---- at-risk work => trash (recoverable), gh never consulted ----

  def test_aged_local_only_commits_are_trashed_regardless_of_pr
    [MERGED, CLOSED, OPEN, NO_PR].each do |pr|
      Dir.mktmpdir do |dir|
        make_repo(dir, "platform") # local-only commit, no remote
        action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: pr)
        assert_equal :trash, action, "aged local-only commits should be trashed"
        assert_match(/aged out: local-only commits in platform/, reason)
      end
    end
  end

  def test_aged_uncommitted_changes_are_trashed
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform", remote: true)
      File.write(File.join(repo, "f.txt"), "dirty")
      action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :trash, action
      assert_match(/aged out: uncommitted changes in platform/, reason)
    end
  end

  def test_aged_detached_head_is_trashed_without_pr_check
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      git(repo, "checkout", "-q", "--detach")
      File.write(File.join(repo, "f.txt"), "more")
      git(repo, "commit", "-qam", "detached work")
      pr = ->(_s, _b) { flunk "aged-out detached dir must not consult gh" }
      action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: pr)
      assert_equal :trash, action
      assert_match(/aged out: detached HEAD in platform/, reason)
    end
  end

  def test_aged_stashed_changes_are_trashed
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform", remote: true) # clean + pushed otherwise
      File.write(File.join(repo, "f.txt"), "wip")
      git(repo, "stash", "push", "-q")
      action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :trash, action
      assert_match(/aged out: stashed changes in platform/, reason)
    end
  end

  def test_aged_loose_nonrepo_content_is_trashed
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # clean + pushed
      FileUtils.mkdir_p(File.join(dir, "notes"))
      File.write(File.join(dir, "notes", "findings.md"), "irreplaceable")
      action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :trash, action
      assert_match(/aged out: unexpected non-repo content/, reason)
    end
  end

  def test_aged_multi_repo_trashed_when_one_repo_has_local_work
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # clean + pushed
      make_repo(dir, "platform")                # local-only, no remote
      action, reason = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :trash, action
      assert_match(/platform/, reason)
    end
  end

  def test_aged_empty_dir_is_hard_deleted
    Dir.mktmpdir do |dir|
      action, = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  def test_aged_symlink_only_dir_is_hard_deleted
    Dir.mktmpdir do |dir|
      File.symlink("/tmp", File.join(dir, "devops"))
      action, = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :delete, action, "a dir holding only symlinks loses nothing on delete"
    end
  end

  def test_aged_symlinked_repo_subdir_is_ignored
    Dir.mktmpdir do |dir|
      real = make_repo(Dir.mktmpdir, "shared") # dirty real repo elsewhere
      File.write(File.join(real, "f.txt"), "dirty")
      File.symlink(real, File.join(dir, "devops"))
      # only a symlink inside => effectively empty => hard delete, real repo untouched
      action, = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  def test_aged_top_level_clone_with_tracked_files_is_not_flagged_as_loose
    Dir.mktmpdir do |parent|
      # repo cloned AT the feature-dir top level: its own files are git-tracked,
      # so git_clean? covers them and they must not read as "loose content".
      dir = make_repo(parent, "feature", remote: true)
      refute ai_dir_has_loose_content?(dir, ai_dir_repos(dir))
      action, = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :delete, action
    end
  end

  def test_aged_clean_pushed_dir_has_no_pr_notes
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true)
      action, _reason, notes = classify_ai_dir(dir, cutoff_time: AGED_CUTOFF, pr_state: NO_PR)
      assert_equal :delete, action
      assert_empty notes
    end
  end

  # ================================================================
  # RECENT (cutoff in the past): full protection, gh consulted.
  # ================================================================

  # ---- clean + pushed, nothing landed => kept by recency, gh never hit ----

  def test_recent_clean_pushed_dir_is_kept_by_recency
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform", remote: true)
      pr = ->(_s, _b) { flunk "no local-only commits => PR must not be consulted" }
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: pr)
      assert_equal :keep, action
      assert_equal "modified within cutoff", reason
    end
  end

  # ---- local-only commits gated on PR state ----

  def test_recent_local_only_commits_with_merged_pr_is_deleted
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: MERGED)
      assert_equal :delete, action
    end
  end

  def test_recent_local_only_commits_with_closed_pr_is_deleted
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: CLOSED)
      assert_equal :delete, action
    end
  end

  def test_recent_local_only_commits_with_open_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: OPEN)
      assert_equal :keep, action
      assert_match(/local-only commits.*platform#7 OPEN/, reason)
    end
  end

  def test_recent_local_only_commits_with_no_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/no PR/, reason)
    end
  end

  # ---- at-risk work is protected while recent ----

  def test_recent_uncommitted_changes_kept_even_when_merged
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      File.write(File.join(repo, "f.txt"), "dirty")
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: MERGED)
      assert_equal :keep, action
      assert_match(/uncommitted changes/, reason)
    end
  end

  def test_recent_detached_head_is_kept_before_any_pr_check
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      git(repo, "checkout", "-q", "--detach")
      File.write(File.join(repo, "f.txt"), "more")
      git(repo, "commit", "-qam", "detached work")
      pr = ->(_s, _b) { flunk "detached repo must be kept before any PR check" }
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: pr)
      assert_equal :keep, action
      assert_match(/detached HEAD/, reason)
    end
  end

  def test_recent_stashed_changes_are_kept
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform", remote: true)
      File.write(File.join(repo, "f.txt"), "wip")
      git(repo, "stash", "push", "-q")
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/stashed changes/, reason)
    end
  end

  def test_recent_loose_nonrepo_content_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true)
      FileUtils.mkdir_p(File.join(dir, "notes"))
      File.write(File.join(dir, "notes", "findings.md"), "irreplaceable")
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/non-repo content/, reason)
    end
  end

  def test_recent_dir_with_merged_pr_is_deleted
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only commit, but its PR merged
      action, = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: MERGED)
      assert_equal :delete, action
    end
  end

  def test_recent_multi_repo_kept_when_one_repo_unsafe
    Dir.mktmpdir do |dir|
      make_repo(dir, "acumen-ui", remote: true) # safe
      make_repo(dir, "platform")                # local-only, no PR => unsafe
      action, reason = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/platform/, reason)
    end
  end

  # ---- PR tie surfaced in output (recent, merged) ----

  def test_recent_merged_pr_number_and_state_surface_in_notes
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only commit
      action, _reason, notes = classify_ai_dir(dir, cutoff_time: RECENT_CUTOFF, pr_state: TestDevAidirs.pr(:merged, 1204))
      assert_equal :delete, action
      assert_equal ["platform#1204 MERGED"], notes
    end
  end

  # ================================================================
  # helpers
  # ================================================================

  def test_gh_pr_state_missing_binary_degrades_to_nil
    # Simulate `gh` absent by emptying PATH; the lookup must return nil (keep),
    # not raise Errno::ENOENT mid-scan.
    old = ENV["PATH"]
    ENV["PATH"] = ""
    assert_nil gh_pr_state("mbryzek/platform", "some-branch")
  ensure
    ENV["PATH"] = old
  end

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
