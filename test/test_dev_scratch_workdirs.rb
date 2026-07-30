#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../bin/dev', __dir__)

# Covers the scratch-workdir purge that `dev codegen sync` and
# `dev browserslist update` run before cloning. The selection rules that matter:
# only <prefix>.* dirs are candidates, the current run's dir is never touched,
# and a dir modified inside SCRATCH_ACTIVE_WINDOW_SECS is left alone because it
# may belong to a sweep that is still running.
class TestDevScratchWorkdirs < Minitest::Test
  PREFIX = "codegen-sync".freeze

  def setup
    @root = Dir.mktmpdir("scratch-root")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # A dir aged out of the active window (mtime older than the window).
  def stale_dir(name, bytes: 0)
    dir = File.join(@root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "f"), "x" * bytes) if bytes.positive?
    old = Time.now - SCRATCH_ACTIVE_WINDOW_SECS - 60
    File.utime(old, old, dir)
    dir
  end

  # A dir touched just now — inside the active window.
  def fresh_dir(name)
    dir = File.join(@root, name)
    FileUtils.mkdir_p(dir)
    dir
  end

  def stale(prefix: PREFIX, keep: nil)
    stale_scratch_workdirs(prefix, keep: keep, root: @root)
  end

  def test_selects_aged_out_dirs_with_the_prefix
    a = stale_dir("#{PREFIX}.20260701-010101")
    b = stale_dir("#{PREFIX}.20260702-020202")
    assert_equal [a, b].sort, stale
  end

  def test_ignores_dirs_with_other_prefixes
    stale_dir("browserslist.20260701")
    stale_dir("platform")
    assert_empty stale
  end

  # The bare prefix with no `.<stamp>` suffix is a different thing entirely (a real
  # repo checkout would look like this) — the glob must not match it.
  def test_ignores_the_bare_prefix_dir
    stale_dir(PREFIX)
    assert_empty stale
  end

  def test_keeps_the_current_runs_dir
    current = stale_dir("#{PREFIX}.20260703-030303")
    other = stale_dir("#{PREFIX}.20260701-010101")
    assert_equal [other], stale(keep: current)
  end

  # A sweep clones everything up front then works inside the clones, so a
  # recently-touched dir may still be an in-flight run. Never delete it.
  def test_keeps_dirs_modified_inside_the_active_window
    fresh_dir("#{PREFIX}.20260704-040404")
    assert_empty stale
  end

  def test_ignores_files_and_symlinks
    File.write(File.join(@root, "#{PREFIX}.log"), "not a dir")
    target = stale_dir("real-target")
    link = File.join(@root, "#{PREFIX}.link")
    File.symlink(target, link)
    assert_empty stale
  end

  def test_purge_deletes_stale_dirs_and_leaves_the_rest
    doomed = stale_dir("#{PREFIX}.20260701-010101", bytes: 4096)
    current = stale_dir("#{PREFIX}.20260703-030303")
    active = fresh_dir("#{PREFIX}.20260704-040404")

    capture_io { purge_scratch_workdirs(PREFIX, keep: current, root: @root) }
    refute File.exist?(doomed)
    assert File.directory?(current)
    assert File.directory?(active)
  end

  def test_purge_reports_what_it_removed
    stale_dir("#{PREFIX}.20260701-010101", bytes: 4096)
    out, _ = capture_io { purge_scratch_workdirs(PREFIX, root: @root) }
    assert_includes out, "codegen-sync.20260701-010101"
    assert_includes out, "Reclaimed"
  end

  def test_purge_is_silent_when_there_is_nothing_to_remove
    fresh_dir("#{PREFIX}.20260704-040404")
    out, _ = capture_io { assert_equal 0, purge_scratch_workdirs(PREFIX, root: @root) }
    assert_empty out
  end

  def test_format_bytes
    assert_equal "0 B", format_bytes(0)
    assert_equal "512 B", format_bytes(512)
    assert_equal "1.0 KB", format_bytes(1024)
    assert_equal "2.5 MB", format_bytes(2.5 * 1024 * 1024)
    assert_equal "1.1 GB", format_bytes(1.1 * 1024 * 1024 * 1024)
  end

  def test_dir_size_bytes_reports_something_for_a_real_dir
    dir = stale_dir("#{PREFIX}.20260701-010101", bytes: 200_000)
    assert_operator dir_size_bytes(dir), :>=, 200_000
  end

  def test_dir_size_bytes_is_zero_for_a_missing_path
    assert_equal 0, dir_size_bytes(File.join(@root, "nope"))
  end
end
