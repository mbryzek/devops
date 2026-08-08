#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev agent status-file` — the morning briefing's status reports, as a command
# (ISS-1022).
#
# The command exists because a filesystem write could not be reconciled with the
# guardrail. `agent/instructions.md` §3 says an autonomous session never edits
# outside its workspace and offers one remedy — clone it — which accomplishes
# nothing when the briefing reads the original path. Three playbooks ended by
# telling the session to write there anyway, so every night, on every runner, a
# session picked a rule to break unaided. The reading that honours the guardrail
# is the one that drops the briefing update, and a dropped section does not read
# as stale: it DISAPPEARS.
#
# So the tests that matter are the refusals. Every mistake on this path produces
# a file that was written successfully and is never read by anything, with no
# error anywhere — which is the same observable state as the job having quietly
# stopped running. A refusal is the only way that becomes findable.
class TestDevAgentStatusFile < Minitest::Test
  include DevTestSupport

  KEY = "slow-query-review".freeze
  FILE = "slow-query-review-status.md".freeze

  def with_data_dir(exists: true)
    Dir.mktmpdir do |dir|
      target = exists ? dir : File.join(dir, "absent")
      Briefing.send(:remove_const, :DATA_DIR)
      Briefing.const_set(:DATA_DIR, target)
      yield target
    end
  ensure
    Briefing.send(:remove_const, :DATA_DIR)
    Briefing.const_set(:DATA_DIR, File.expand_path("~/code/openclaw/openclaw-workspace/data"))
  end

  def with_report(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.md")
      File.write(path, text)
      yield path
    end
  end

  def today_report(status: "pr-opened")
    "Last run: #{Briefing.today} 03:47 ET\nStatus: #{status}\n\nNothing crossed the bar.\n"
  end

  # Runs the command capturing all three of stdout, stderr and the exit status,
  # because which STREAM a message lands on is part of the contract here:
  # `dev agent status-file <key> > s.md` has to capture what the briefing reads
  # and nothing else.
  def run_status_file(args)
    status = nil
    out = +""
    err = +""
    stdout, stderr = StringIO.new, StringIO.new
    old_out, old_err = $stdout, $stderr
    $stdout, $stderr = stdout, stderr
    begin
      cmd_agent_status_file(args)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = old_out, old_err
      out = stdout.string
      err = stderr.string
    end
    [out, err, status]
  end

  # ---- the write, which is the whole point ----

  def test_a_report_is_written_to_the_file_the_briefing_reads
    with_data_dir do |dir|
      with_report(today_report) do |path|
        out, _err, status = run_status_file([KEY, "--write", path])
        assert_nil status
        assert_equal today_report, File.read(File.join(dir, FILE))
        assert_includes out, FILE
        assert_includes out, "Last run: #{Briefing.today}"
      end
    end
  end

  def test_the_write_is_atomic_and_leaves_no_tmp_file
    with_data_dir do |dir|
      with_report(today_report) do |path|
        run_status_file([KEY, "--write", path])
        assert_equal [FILE], Dir.children(dir).sort
      end
    end
  end

  # ---- the refusals ----

  # The failure this command was built to remove, in its purest form: the write
  # succeeds, and the briefing — which dates every section off line one — never
  # opens the file again. A session has no way to discover that, so it is refused
  # here, before anything is written.
  def test_a_body_the_briefing_cannot_date_is_refused_and_nothing_is_written
    with_data_dir do |dir|
      with_report("Status: pr-opened\nLast run: #{Briefing.today}\n") do |path|
        _out, err, status = run_status_file([KEY, "--write", path])
        assert_equal 1, status
        assert_match(/Last run: YYYY-MM-DD/, err)
        assert_empty Dir.children(dir), "a body the briefing cannot read must not reach the disk"
      end
    end
  end

  def test_an_empty_report_is_refused
    with_data_dir do |dir|
      with_report("\n  \n") do |path|
        _out, err, status = run_status_file([KEY, "--write", path])
        assert_equal 1, status
        assert_match(/empty/, err)
        assert_empty Dir.children(dir)
      end
    end
  end

  def test_an_unregistered_key_is_refused_with_the_keys_that_exist
    with_data_dir do
      with_report(today_report) do |path|
        _out, err, status = run_status_file(["slow-query-reveiw", "--write", path])
        assert_equal 1, status
        assert_match(/slow-query-reveiw/, err)
        assert_match(/slow-query-review/, err)
      end
    end
  end

  def test_a_report_file_that_does_not_exist_is_refused
    with_data_dir do
      _out, err, status = run_status_file([KEY, "--write", "/nonexistent/report.md"])
      assert_equal 1, status
      assert_match(%r{No such file: /nonexistent/report.md}, err)
    end
  end

  def test_write_without_a_key_says_which_job_it_needs
    with_data_dir do
      with_report(today_report) do |path|
        _out, err, status = run_status_file(["--write", path])
        assert_equal 1, status
        assert_match(/needs a key/, err)
        assert_match(/slow-query-review/, err)
      end
    end
  end

  # Best effort is right for a producer whose chore already ran; it is wrong here.
  # This caller was TOLD to record something, so a no-op has to fail the shell —
  # otherwise the session reports success and the section goes dark anyway, which
  # is the exact outcome the command exists to prevent.
  def test_a_missing_briefing_workspace_fails_loudly_rather_than_silently
    with_data_dir(exists: false) do
      with_report(today_report) do |path|
        _out, err, status = run_status_file([KEY, "--write", path])
        assert_equal 1, status
        assert_match(/no briefing workspace/i, err)
        assert_match(/dev issues workaround/, err)
      end
    end
  end

  # Warned, not refused: a run that started at 23:50 and finished after midnight
  # wrote an honest header, and failing it at its last step would be worse than
  # the skipped section. The warning is what makes that section explicable.
  def test_a_date_that_is_not_today_is_warned_about_and_still_written
    with_data_dir do |dir|
      with_report("Last run: 2026-01-02\nStatus: no-data\n") do |path|
        _out, err, status = run_status_file([KEY, "--write", path])
        assert_nil status
        assert_match(/will skip this section/, err)
        assert_equal "Last run: 2026-01-02\nStatus: no-data\n", File.read(File.join(dir, FILE))
      end
    end
  end

  # ---- the reads ----

  def test_the_catalogue_reports_each_key_by_the_briefings_own_freshness_rule
    with_data_dir do |dir|
      File.write(File.join(dir, FILE), "Last run: #{Briefing.today}\nStatus: pr-opened\n")
      File.write(File.join(dir, "docker-prune-status.md"), "Last run: 2026-01-02 — ok\n")
      File.write(File.join(dir, "aidirs-prune-status.md"), "nothing to prune\n")

      out, _err, status = run_status_file([])
      assert_nil status
      assert_match(/slow-query-review\s+#{Regexp.escape(FILE)}\s+today/, out)
      assert_match(/docker-prune.*2026-01-02 — stale/, out)
      assert_match(/aidirs-prune.*UNDATED/, out)
      assert_match(/daily-perf-prs.*never written/, out)
    end
  end

  # The stdout/stderr split `dev agent playbook` uses, for the same reason: the
  # round trip is `> s.md`, edit, `--write s.md`, and a banner in the captured
  # file is a header the briefing then fails to parse.
  def test_reading_a_key_puts_the_body_on_stdout_and_the_path_on_stderr
    with_data_dir do |dir|
      File.write(File.join(dir, FILE), today_report)
      out, err, status = run_status_file([KEY])
      assert_nil status
      assert_equal today_report, out
      assert_match(/#{Regexp.escape(FILE)}/, err)
      refute_match(/Last run/, err)
    end
  end

  def test_reading_a_key_that_was_never_written_says_so
    with_data_dir do
      _out, err, status = run_status_file([KEY])
      assert_equal 1, status
      assert_match(/No status file for `#{KEY}`/, err)
    end
  end

  def test_it_is_a_registered_subcommand_with_a_usage_line
    assert_includes SUBCOMMANDS["agent"], "status-file"
    assert INVOCATIONS.key?("agent status-file")
    assert_includes USAGE, INVOCATIONS["agent status-file"]
  end
end
