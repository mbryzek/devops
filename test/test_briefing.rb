#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/briefing'

# The morning briefing's status files.
#
# The failure mode being guarded here is silent and total: the briefing skips any
# section whose `Last run:` line is not today, so a job that stops writing its
# file does not report an error — the section simply disappears and nobody
# notices. That is exactly what would happen if a producer took a job over
# without carrying its status file across.
class TestBriefing < Minitest::Test
  include DevTestSupport

  def with_data_dir
    Dir.mktmpdir do |dir|
      Briefing.send(:remove_const, :DATA_DIR)
      Briefing.const_set(:DATA_DIR, dir)
      yield dir
    end
  ensure
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, File.expand_path("~/code/openclaw/openclaw-workspace/data"))
  end

  def test_writes_the_file_and_terminates_it_with_a_newline
    with_data_dir do |dir|
      assert Briefing.write("x.md", "Last run: 2026-08-04 — ok")
      assert_equal "Last run: 2026-08-04 — ok\n", File.read(File.join(dir, "x.md"))
    end
  end

  def test_does_not_double_the_trailing_newline
    with_data_dir do |dir|
      Briefing.write("x.md", "a\n")
      assert_equal "a\n", File.read(File.join(dir, "x.md"))
    end
  end

  def test_leaves_no_tmp_file_behind
    with_data_dir do |dir|
      Briefing.write("x.md", "a")
      assert_equal ["x.md"], Dir.children(dir).sort
    end
  end

  # Best effort by design: the chore ran whether or not the briefing hears about
  # it, and a missing openclaw workspace must not turn a successful prune into a
  # failed producer run.
  def test_missing_data_dir_is_reported_but_never_raises
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, "/nonexistent/openclaw/data")
    refute Briefing.write("x.md", "a")
  ensure
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, File.expand_path("~/code/openclaw/openclaw-workspace/data"))
  end

  def test_today_is_the_iso_date_the_briefing_compares_against
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, Briefing.today)
  end
end
