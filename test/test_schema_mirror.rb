#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# The fallback checkout `claude-db sync` reads migration scripts from when the
# caller has none of their own.
#
# It used to be ~/code/<app>-postgresql, a tree no autonomous session may write
# to and therefore no session can pull: on 2026-08-05 it was 12 migrations
# behind main and every platform session on that runner inherited the gap as
# failing tests (ISS-545). These tests pin the two properties that fix it — the
# mirror ends up AT origin/main whatever state it was in, and a mirror that
# cannot be refreshed degrades to the last good one rather than to nothing.
class TestSchemaMirror < Minitest::Test
  include DevTestSupport

  # A bare origin holding one migration, and a working clone to publish more
  # from. Real git, because every property here is a git property.
  def with_origin
    Dir.mktmpdir do |root|
      origin = File.join(root, "platform-postgresql.git")
      work   = File.join(root, "work")
      git!(root, "init", "--quiet", "--bare", "--initial-branch=main", origin)
      git!(root, "clone", "--quiet", origin, work)
      git!(work, "config", "user.email", "test@example.com")
      git!(work, "config", "user.name", "test")
      add_script(work, "20260101000000.sql")
      git!(work, "push", "--quiet", "origin", "main")
      yield(root, origin, work)
    end
  end

  def git!(dir, *args)
    ok = system("git", *args, :chdir => dir, :out => File::NULL, :err => File::NULL)
    raise "git #{args.join(' ')} failed in #{dir}" unless ok
  end

  def add_script(repo, name)
    FileUtils.mkdir_p(File.join(repo, "scripts"))
    File.write(File.join(repo, "scripts", name), "select 1;\n")
    git!(repo, "add", "-A")
    git!(repo, "commit", "--quiet", "-m", name)
  end

  def scripts_in(dir)
    Dir[File.join(dir, "scripts", "*.sql")].map { |p| File.basename(p) }.sort
  end

  # ── the mirror is created, and it is at main ──────────────────────────────

  def test_checkout_clones_from_the_url_the_existing_checkout_uses
    with_origin do |root, _origin, work|
      mirrors = File.join(root, "mirrors")
      dir = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      assert_equal File.join(mirrors, "platform-postgresql"), dir
      assert_equal ["20260101000000.sql"], scripts_in(dir)
    end
  end

  # The whole point: whatever main gained since the mirror was last used is
  # there the next time it is asked for. This is the case the stale
  # ~/code checkout could never satisfy.
  def test_checkout_picks_up_migrations_merged_since_the_last_use
    with_origin do |root, _origin, work|
      mirrors = File.join(root, "mirrors")
      dir = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      assert_equal ["20260101000000.sql"], scripts_in(dir)

      add_script(work, "20260202000000.sql")
      git!(work, "push", "--quiet", "origin", "main")

      again = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      assert_equal dir, again
      assert_equal ["20260101000000.sql", "20260202000000.sql"], scripts_in(again)
    end
  end

  # A stray .sql in scripts/ would be handed to sem-apply as if it were a
  # released migration, so the mirror is cleaned as well as reset.
  def test_checkout_discards_local_edits_and_untracked_scripts
    with_origin do |root, _origin, work|
      mirrors = File.join(root, "mirrors")
      dir = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      File.write(File.join(dir, "scripts", "99999999999999.sql"), "drop table users;\n")
      File.write(File.join(dir, "scripts", "20260101000000.sql"), "-- clobbered\n")

      again = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      assert_equal ["20260101000000.sql"], scripts_in(again)
      assert_equal "select 1;\n", File.read(File.join(again, "scripts", "20260101000000.sql"))
    end
  end

  # ── degrading, never blocking ─────────────────────────────────────────────

  # Offline with a mirror already on disk: its last known main still beats the
  # checkout nobody can pull, so it is used as it stands rather than refused.
  def test_unreachable_origin_keeps_the_existing_mirror
    with_origin do |root, origin, work|
      mirrors = File.join(root, "mirrors")
      dir = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      FileUtils.rm_rf(origin)

      again = SchemaMirror.checkout("platform", :origin_from => work, :root => mirrors)
      assert_equal dir, again
      assert_equal ["20260101000000.sql"], scripts_in(again)
    end
  end

  # Offline with no mirror yet: nil, and the caller keeps whatever checkout it
  # would have used anyway. An unknown must never become a block.
  def test_unreachable_origin_with_no_mirror_returns_nil
    with_origin do |root, origin, work|
      FileUtils.rm_rf(origin)
      assert_nil SchemaMirror.checkout("platform", :origin_from => work,
                                       :root => File.join(root, "mirrors"))
    end
  end

  def test_checkout_returns_nil_when_the_source_checkout_has_no_origin
    Dir.mktmpdir do |root|
      plain = File.join(root, "not-a-clone")
      FileUtils.mkdir_p(plain)
      assert_nil SchemaMirror.origin_url(plain)
      assert_nil SchemaMirror.checkout("platform", :origin_from => plain,
                                       :root => File.join(root, "mirrors"))
    end
  end

  # A half-cloned or empty directory would sync a database to nothing and report
  # it up to date, which is the false green the whole change exists to remove.
  def test_a_mirror_without_scripts_is_not_usable
    Dir.mktmpdir do |dir|
      refute SchemaMirror.usable?(dir)
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      refute SchemaMirror.usable?(dir)
      File.write(File.join(dir, "scripts", "1.sql"), "")
      assert SchemaMirror.usable?(dir)
    end
  end

  # It lives beside the port history under ~/code/ai — the shared root a human
  # and an agent can both reach — and is dotted so nothing listing feature
  # directories adopts it as one.
  def test_default_root_is_hidden_under_the_shared_ai_directory
    assert_equal File.expand_path("~/code/ai"), File.dirname(SchemaMirror::ROOT)
    assert File.basename(SchemaMirror::ROOT).start_with?(".")
    assert_equal File.expand_path("~/code/ai/.claude-db-schema/acumen-postgresql"),
                 SchemaMirror.path("acumen")
  end
end
