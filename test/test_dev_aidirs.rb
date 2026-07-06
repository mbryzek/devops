#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev ai prune`'s classification: which ~/code/ai feature dirs are safe to
# delete. The rule is "keep unless proven disposable" — a dir is deleted only when
# every real git repo inside is clean AND either fully pushed or its branch's PR is
# merged/closed. Recent activity, uncommitted changes, and local-only commits with
# no merged/closed PR all protect a dir. gh is stubbed via the injected pr_state so
# no network is touched; git state is exercised against real temp repos.
class TestDevAidirs < Minitest::Test
  # cutoff far in the future => every temp dir counts as "modified within cutoff",
  # so pass PAST to reach the git checks and FUTURE to assert the recency guard.
  PAST   = Time.now - 3600
  FUTURE = Time.now + 3600
  NO_PR  = ->(_slug, _branch) { nil }

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

  # Give a repo an origin whose main already contains HEAD, so nothing is local-only.
  def push_to_bare_remote(parent, repo)
    bare = File.join(parent, "#{File.basename(repo)}.git")
    git(repo, "clone", "--bare", "-q", repo, bare) rescue system("git", "clone", "--bare", "-q", repo, bare)
    git(repo, "remote", "add", "origin", "git@github.com:mbryzek/#{File.basename(repo)}.git")
    # point a tracking ref at HEAD without a real network remote
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
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: ->(_s, _b) { :merged })
      assert_equal :delete, action
    end
  end

  def test_local_only_commits_with_closed_pr_is_deletable
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: ->(_s, _b) { :closed })
      assert_equal :delete, action
    end
  end

  def test_local_only_commits_with_open_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: ->(_s, _b) { :open })
      assert_equal :keep, action
      assert_match(/local-only commits.*open/, reason)
    end
  end

  def test_local_only_commits_with_no_pr_is_kept
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: NO_PR)
      assert_equal :keep, action
      assert_match(/PR: none/, reason)
    end
  end

  # ---- uncommitted changes always win ----

  def test_uncommitted_changes_kept_even_when_merged
    Dir.mktmpdir do |dir|
      repo = make_repo(dir, "platform")
      File.write(File.join(repo, "f.txt"), "dirty")
      action, reason = classify_ai_dir(dir, cutoff_time: FUTURE, pr_state: ->(_s, _b) { :merged })
      assert_equal :keep, action
      assert_match(/uncommitted changes/, reason)
    end
  end

  # ---- recency guard ----

  def test_recent_activity_is_kept_before_any_git_check
    Dir.mktmpdir do |dir|
      make_repo(dir, "platform") # local-only + would otherwise need a PR
      # PAST cutoff => freshly made dir is newer => recent => kept, PR never checked
      pr = ->(_s, _b) { flunk "should not reach PR check for a recent dir" }
      action, reason = classify_ai_dir(dir, cutoff_time: PAST, pr_state: pr)
      assert_equal :keep, action
      assert_equal "modified within cutoff", reason
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
