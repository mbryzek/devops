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
#
# Every test here is of that one failure shape, reached a different way: a job
# that never writes, a job that writes under a name nothing reads, and a job that
# writes a body the briefing cannot date. All three are indistinguishable from
# outside, which is why the key registry is closed and the header is parsed here
# rather than trusted.
class TestBriefing < Minitest::Test
  include DevTestSupport

  KEY = "docker-prune".freeze

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
      assert Briefing.write(KEY, "Last run: 2026-08-04 — ok")
      assert_equal "Last run: 2026-08-04 — ok\n", File.read(File.join(dir, "docker-prune-status.md"))
    end
  end

  def test_does_not_double_the_trailing_newline
    with_data_dir do |dir|
      Briefing.write(KEY, "a\n")
      assert_equal "a\n", File.read(File.join(dir, "docker-prune-status.md"))
    end
  end

  def test_leaves_no_tmp_file_behind
    with_data_dir do |dir|
      Briefing.write(KEY, "a")
      assert_equal ["docker-prune-status.md"], Dir.children(dir).sort
    end
  end

  # Best effort by design: the chore ran whether or not the briefing hears about
  # it, and a missing openclaw workspace must not turn a successful prune into a
  # failed producer run. The CLI turns this false into a loud error, because its
  # caller was TOLD to record something — see test_dev_agent_status_file.rb.
  def test_missing_data_dir_is_reported_but_never_raises
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, "/nonexistent/openclaw/data")
    refute Briefing.write(KEY, "a")
  ensure
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, File.expand_path("~/code/openclaw/openclaw-workspace/data"))
  end

  def test_today_is_the_iso_date_the_briefing_compares_against
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, Briefing.today)
  end

  # ---- the key registry (ISS-1022) ----
  #
  # Callers name a JOB, never a filename. The filenames are not derivable — three
  # of the six break the `<key>-status.md` pattern — so a caller that spelled one
  # would sooner or later spell one wrong, and a wrong filename does not fail: it
  # writes successfully, under a name the briefing never opens.

  def test_a_key_resolves_to_the_file_the_briefing_reads
    assert_equal "slow-query-review-status.md", Briefing.file_for("slow-query-review")
    assert_equal "browserslist-status.md", Briefing.file_for("browserslist-update")
    assert_equal "platform-memory-improvement.md", Briefing.file_for("platform-memory-improvement")
  end

  # The whole reason the registry is closed. A typo has to be an error at the
  # moment of the write, because nothing downstream will ever report it.
  def test_an_unregistered_key_raises_rather_than_writing_a_file_nothing_reads
    with_data_dir do |dir|
      e = assert_raises(Briefing::UnknownKey) { Briefing.write("slow-query-reveiw", "Last run: 2026-08-08") }
      assert_match(/slow-query-reveiw/, e.message)
      assert_match(/slow-query-review/, e.message, "the message must name the keys that DO exist")
      assert_empty Dir.children(dir)
    end
  end

  # UnknownKey is a programmer error and must survive the best-effort rescue that
  # swallows everything else — a producer with a typo'd key would otherwise warn
  # once into a log nobody reads and carry on reporting success.
  def test_an_unregistered_key_is_not_swallowed_by_the_best_effort_rescue
    assert_raises(Briefing::UnknownKey) { Briefing.write("nope", "a") }
  end

  def test_every_registered_key_has_a_markdown_file_and_no_duplicates
    assert_equal Briefing::FILES.values.uniq, Briefing::FILES.values, "two keys pointing at one file"
    Briefing::FILES.each do |key, file|
      assert_match(/\A[a-z0-9-]+\z/, key, "#{key} is not a plain job key")
      assert_match(/\.md\z/, file, "#{file} is not a markdown file")
    end
  end

  # ---- the header the briefing dates each section by ----

  def test_the_header_date_is_read_off_the_first_line
    assert_equal "2026-08-08", Briefing.header_date("Last run: 2026-08-08 — ok\nmore\n")
    assert_equal "2026-08-08", Briefing.header_date("Last run: 2026-08-08 03:47 ET\nStatus: pr-opened\n")
    assert_equal "2026-08-05", Briefing.header_date("Last run: 2026-08-05 (check only, nothing pushed)\n")
  end

  # Every shape here is a section that silently never renders: the briefing dates
  # by line ONE, so a header further down, a different word, or a partial date is
  # the same as no header at all.
  def test_a_body_the_briefing_cannot_date_reads_as_no_date
    assert_nil Briefing.header_date("# Weekly Review: apibuilder-ui — 2026-08-05\n\nLast run: 2026-08-05\n")
    assert_nil Briefing.header_date("Last Run: 2026-08-08\n")
    assert_nil Briefing.header_date("Last run: 2026-8-8\n")
    assert_nil Briefing.header_date("")
  end

  def test_reading_a_key_that_was_never_written_is_nil_rather_than_an_error
    with_data_dir do
      assert_nil Briefing.read(KEY)
      Briefing.write(KEY, "Last run: 2026-08-08 — ok")
      assert_equal "Last run: 2026-08-08 — ok\n", Briefing.read(KEY)
    end
  end
end
