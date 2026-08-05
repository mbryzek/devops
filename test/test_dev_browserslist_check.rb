#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev browserslist update --check` (ISS-525).
#
# The pushing sweep is no longer scheduled by anything: the `browserslist-update`
# producer files an issue and the claiming session runs THIS mode first, opening
# a normal PR per repo it names. So the exit code is a contract with a session,
# not local detail — 0 nothing to do, 1 findings to act on, 2 the check itself
# could not run — and getting it wrong is silent in both directions. A wrong 0
# dismisses an issue that should have shipped PRs; a wrong 1 sends a session to
# open PRs for repos that are already current.
class TestBrowserslistCheckExitCode < Minitest::Test
  def code(pending: [], no_changes: [], failures: [])
    browserslist_check_exit_code(pending: pending, no_changes: no_changes, failures: failures)
  end

  def test_clean_when_every_repo_was_examined_and_none_changed
    assert_equal BROWSERSLIST_EXIT_CLEAN, code(no_changes: %w[rallyd hackathon])
  end

  def test_findings_when_a_repo_needs_updating
    assert_equal BROWSERSLIST_EXIT_FINDINGS, code(pending: %w[rallyd], no_changes: %w[hackathon])
  end

  # A repo that demonstrably regenerated to a diff is a real finding even when a
  # sibling failed to clone. Exit 2 would drop it on the floor until next Monday.
  def test_findings_win_over_a_broken_sibling_repo
    assert_equal BROWSERSLIST_EXIT_FINDINGS, code(pending: %w[rallyd], failures: ["hackathon (clone failed)"])
  end

  def test_uncheckable_when_a_repo_failed_and_none_needed_updating
    assert_equal BROWSERSLIST_EXIT_UNCHECKABLE, code(no_changes: %w[rallyd], failures: %w[hackathon])
  end

  # "Examined nothing" is never evidence that caniuse-lite is current — it is the
  # state a bad `--app` filter or an empty ~/code produces.
  def test_uncheckable_when_nothing_was_examined
    assert_equal BROWSERSLIST_EXIT_UNCHECKABLE, code
  end

  # The verdict is what the session reads to decide what to do next, so it has to
  # name the repos rather than report that there is drift somewhere.
  def test_the_findings_verdict_names_the_repos_and_forbids_pushing_to_main
    verdict = browserslist_check_verdict(pending: %w[rallyd hackathon], no_changes: %w[acumen-ui],
                                         failures: [], code: BROWSERSLIST_EXIT_FINDINGS)
    assert_includes verdict, "rallyd"
    assert_includes verdict, "hackathon"
    refute_includes verdict, "acumen-ui"
    assert_includes verdict, "never push to main"
  end

  def test_the_uncheckable_verdict_concludes_nothing
    verdict = browserslist_check_verdict(pending: [], no_changes: [], failures: %w[rallyd],
                                         code: BROWSERSLIST_EXIT_UNCHECKABLE)
    assert_includes verdict, "rallyd"
    assert_includes verdict, "Nothing was concluded"
  end
end

# The morning briefing's "Browserslist Update" section skips any status file whose
# `Last run:` is not today, so whichever mode actually runs on a schedule has to
# write it. After ISS-525 that is the CHECK — nothing schedules the pushing sweep
# any more — and a check that did not write here would take the section dark on
# the day this shipped, which is the exact silent stop the section exists to
# catch.
class TestBrowserslistBriefingStatus < Minitest::Test
  include DevTestSupport

  def body(**kwargs)
    written = nil
    stub_singleton(Briefing, :write, ->(_name, text) { written = text; true }) do
      write_browserslist_briefing_status(**{ updated: [], pending: [], no_changes: [], failures: [],
                                             logs: {}, check: false }.merge(kwargs))
    end
    written
  end

  def test_the_check_reports_pending_repos_without_claiming_anything_was_pushed
    text = body(check: true, pending: %w[rallyd], no_changes: %w[hackathon])
    assert_includes text, "check only, nothing pushed"
    assert_includes text, "Needs update (no PR opened yet): rallyd"
    refute_includes text, "pushed to main"
  end

  def test_the_pushing_sweep_still_says_what_it_pushed
    text = body(updated: %w[rallyd], no_changes: %w[hackathon])
    assert_includes text, "Updated (pushed to main): rallyd"
    refute_includes text, "check only"
  end

  def test_a_clean_check_still_stamps_today_so_the_section_does_not_go_dark
    text = body(check: true, no_changes: %w[rallyd hackathon])
    assert_includes text, "Last run: #{Briefing.today}"
    assert_includes text, "All 2 projects up to date"
  end

  def test_failures_carry_their_captured_output_in_check_mode_too
    text = body(check: true, failures: ["rallyd (clone failed)"], logs: { "rallyd" => "Repository not found" })
    assert_includes text, "Failed: rallyd (clone failed) (Repository not found)"
  end
end

# `--check` has to be consumed as a FLAG. If the arg loop ever stopped
# recognising it, it would fall through to `rest` and the command would abort as
# "takes no positional arguments" — inside a claimed session, four hours of lease
# after the issue was filed. Asserted through the stray-positional path, which
# fires before anything is cloned.
class TestBrowserslistCheckArgs < Minitest::Test
  include DevTestSupport

  def test_check_is_a_flag_not_a_positional
    _, status = capture_stderr_and_exit { cmd_browserslist_update(["--check", "foo"]) }
    assert_equal 1, status, "a stray positional must still be rejected"

    out, status = capture_stderr_and_exit { cmd_browserslist_update(["--check", "--app"]) }
    assert_equal 1, status
    assert_includes out, "--app requires a value",
                    "--check was not consumed as a flag: parsing stopped somewhere else"
  end

  # An unknown `--app` examines nothing, and `Util.exit_with_error` exits 1 —
  # which in check mode would tell the session "this repo needs updating". It
  # scans ~/code for the name and clones nothing, so this is safe to call for
  # real.
  def test_an_unknown_app_is_uncheckable_not_a_finding
    _, status = capture_stderr_and_exit { cmd_browserslist_update(["--check", "--app", "no-such-repo-i525"]) }
    assert_equal BROWSERSLIST_EXIT_UNCHECKABLE, status

    _, status = capture_stderr_and_exit { cmd_browserslist_update(["--app", "no-such-repo-i525"]) }
    assert_equal 1, status, "the pushing sweep's own error path is unchanged"
  end
end
