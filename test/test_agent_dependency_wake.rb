#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/dependency_wake'
require 'agent/tick'
require 'prs/deploy'

# The backstop that brings a dependency-deferred issue back within minutes of the
# merge instead of within a day (ISS-922).
#
# Every assertion here is about one of two failure modes, because between them
# they are the whole risk of the feature:
#
#   WAKING TOO MUCH — a snooze a human set for an unrelated reason, or a deferral
#   whose blocker has NOT merged. The first undoes somebody's deliberate
#   decision; the second dispatches nothing (the claim re-runs the gate and
#   re-defers), but each round trip walks the issue toward the seven-attempt
#   `needs_input` escalation, which is the churn the issue's safety note names.
#
#   WAKING TOO LITTLE — a sweep that silently examines nothing. It looks exactly
#   like a healthy quiet fleet, and the symptom is a day of latency nobody
#   attributes to it.
class TestAgentDependencyWake < Minitest::Test
  include DevTestSupport

  DEFER = Agent::Dependency::DEFER_MARKER
  URL = "https://github.com/mbryzek/platform/pull/2190".freeze

  # A deferral comment as the PLATFORM actually writes it, not as this file used
  # to abbreviate it. `Agent::Tick#defer_for_dependency` hands its text to
  # `Agent::Api.snooze`, and the server puts `IssuesService.snoozeComment`'s
  # sentence in front of it before anything reaches a timeline — so a bare
  # DEFER_MARKER body is a shape that has never existed in production.
  #
  # The fidelity matters now rather than being tidiness: `dependency_deferred?`
  # reads the snooze sentence to tell WHICH snooze an issue is under (ISS-975),
  # so a fixture missing it exercises a case the sweep never sees.
  DEFER_COMMENT = "Snoozed until Aug 9, 2026 at 1:36 AM EDT. #{DEFER} — not dispatched, " \
                  "deferred 1 day (attempt 1 of 7).".freeze

  # What a human parking an issue leaves behind: the same server sentence, with
  # a note that has nothing to do with a dependency.
  def human_snooze(note)
    "Snoozed until Aug 14, 2026 at 10:23 PM EDT. #{note}"
  end

  def snoozed_row(number, until_at: "2026-08-09T01:36:36.000Z")
    { "number" => number.to_s, "status" => "open", "snoozed_until" => until_at }
  end

  def blocked_issue(number, blocker_status: "fixed", until_at: "2026-08-09T01:36:36.000Z")
    { "number" => number.to_s, "snoozed_until" => until_at,
      "links" => [{ "type" => "blocked_by", "direction" => "outgoing",
                    "issue" => { "number" => "890", "status" => blocker_status } }] }
  end

  # One pass with the whole platform and GitHub faked. `timelines` maps issue
  # number => comment bodies; `issues` maps number => the full record the sweep
  # reads; `merged` is the set of fix urls GitHub reports as merged, and
  # `github_readable: false` is a `gh` that answers nothing at all.
  #
  # `writes` collects every mutation, which is what most of these assert on: the
  # question is almost always "did this touch the issue at all".
  #
  # EVERY lambda here closes over locals rather than calling a helper method:
  # `stub_singleton` installs them with `define_singleton_method`, which rebinds
  # `self` to Agent::Api, so a helper call inside one resolves against the module
  # and raises NoMethodError.
  def sweep(rows:, timelines: {}, issues: {}, blocker_fixes: [URL], merged: [URL],
            released: true, github_readable: true, issue_error: false, timeline_error: false,
            wake_error: false, comment_error: false, dry_run: false, cap: 25)
    writes = []
    stub_singleton(Agent::Api, :snoozed_issues, ->(**) { rows }) do
      stub_singleton(Agent::Api, :issue_comments, lambda { |number, **|
        raise ApiError, "500 from the platform" if timeline_error
        Array(timelines[number.to_s]).map { |body| { "body" => body } }
      }) do
        stub_singleton(Agent::Api, :issue, lambda { |number, **|
          raise ApiError, "500 from the platform" if issue_error
          issues.key?(number.to_s) ? issues[number.to_s] : { "fixes" => blocker_fixes.map { |u| { "url" => u } } }
        }) do
          stub_singleton(Agent::Github, :pr_by_url, lambda { |url|
            next nil unless github_readable
            { "url" => url, "state" => merged.include?(url) ? "MERGED" : "OPEN",
              "mergeCommit" => merged.include?(url) ? { "oid" => "deadbeef" } : nil }
          }) do
            stub_singleton(Prs::Deploy, :state, ->(*, **) { released ? :shipped : :unshipped }) do
              stub_singleton(Agent::Api, :wake, lambda { |number, **|
                raise ApiError, "422 from the platform" if wake_error
                writes << [:wake, number.to_s]
              }) do
                stub_singleton(Agent::Api, :comment, lambda { |number, text, **|
                  raise ApiError, "500 from the platform" if comment_error
                  writes << [:comment, number.to_s, text]
                }) do
                  result = Agent::DependencyWake.sweep(use_localhost: false, dry_run: dry_run, cap: cap)
                  return [result, writes]
                end
              end
            end
          end
        end
      end
    end
  end

  # ---- the happy path: ISS-858, which is the issue that produced ISS-922 ----

  def test_a_deferral_whose_fix_has_merged_is_woken
    result, writes = sweep(rows: [snoozed_row(858)],
                           timelines: { "858" => [DEFER_COMMENT] },
                           issues: { "858" => blocked_issue(858) })
    assert_equal %w[858], result.woken
    assert_equal [:wake, "858"], writes.first
    assert_equal :comment, writes.last.first
  end

  # The wake is what matters, so it goes first: a note that could not be posted
  # still leaves the issue correctly back in the queue.
  def test_the_wake_precedes_the_note
    _, writes = sweep(rows: [snoozed_row(858)],
                      timelines: { "858" => [DEFER_COMMENT] },
                      issues: { "858" => blocked_issue(858) })
    assert_equal %i[wake comment], writes.map(&:first)
  end

  # THE counter trap, and it is the reason the note's wording is a test rather
  # than a comment. `defer_attempts` counts comments containing DEFER_MARKER, so
  # a wake note quoting the deferral it undoes would count itself as another
  # attempt — the exact inflation ISS-922 says a merge-driven wake must not cause.
  def test_the_wake_note_resets_the_attempt_count_rather_than_adding_to_it
    _, writes = sweep(rows: [snoozed_row(858)],
                      timelines: { "858" => [DEFER_COMMENT] },
                      issues: { "858" => blocked_issue(858) })
    note = writes.last[2]
    refute_includes note, DEFER, "the wake note must not read as another deferral"
    assert_includes note, Agent::Dependency::WAKE_MARKER
    prior = [{ "body" => DEFER }, { "body" => DEFER }, { "body" => note }]
    assert_equal 0, Agent::Dependency.defer_attempts(prior)
  end

  # ---- waking too much ----

  # A snooze a human set ("confirm the data migration completed") carries no
  # marker and is none of this sweep's business. ISS-238 is a live example.
  def test_a_snooze_nobody_deferred_is_left_alone
    result, writes = sweep(rows: [snoozed_row(238)], timelines: { "238" => ["Waiting a week for data."] })
    assert_empty writes
    assert_equal %w[238], result.skipped
    assert_empty result.woken
  end

  # ISS-975, and the reason this sweep is asked about the CURRENT snooze rather
  # than the whole timeline. ISS-892 was deferred on an unmerged platform#2201,
  # that PR merged, and from then on every snooze anybody put the issue under was
  # lifted within minutes as though this sweep had set it — Mike's, then the
  # seven-day one the session working it set because the issue's own body told it
  # to, 14 seconds after it was written. Four claims in two hours, each re-running
  # an identical read-out against identical data.
  #
  # The old `comments.any?` reading passes every other test in this file and
  # fails this one, because it is the only fixture where a deferral and a later
  # unrelated snooze sit on the SAME timeline.
  def test_a_later_snooze_is_not_this_sweeps_to_lift_however_the_issue_was_deferred_before
    result, writes = sweep(
      rows: [snoozed_row(892)],
      timelines: { "892" => [DEFER_COMMENT,
                             "Snooze cleared; back in the queue.",
                             human_snooze("## No verdict — the pilot is 45 minutes old.")] },
      issues: { "892" => blocked_issue(892) },
    )
    assert_empty writes, "a snooze this sweep did not set must not be lifted"
    assert_equal %w[892], result.skipped
    assert_empty result.woken
  end

  # The other side of the same tense, so the fix cannot be "never wake anything":
  # an issue deferred, woken, and deferred AGAIN is under a deferral now, and the
  # older comments do not stop it being lifted.
  def test_a_reinstated_deferral_is_still_woken
    result, writes = sweep(
      rows: [snoozed_row(858)],
      timelines: { "858" => [DEFER_COMMENT,
                             "Snooze cleared; back in the queue.",
                             human_snooze("Parking this until the migration lands."),
                             "Snooze cleared; back in the queue.",
                             DEFER_COMMENT] },
      issues: { "858" => blocked_issue(858) },
    )
    assert_equal %w[858], result.woken
    assert_equal [:wake, "858"], writes.first
  end

  # A snooze with nothing on the timeline explaining it — the server always
  # writes the sentence, so this is a shape that means something has changed
  # underneath. It reads as "not mine", which leaves the issue to the daily
  # expiry that predates this sweep entirely.
  def test_a_snooze_with_no_comment_explaining_it_is_left_alone
    result, writes = sweep(rows: [snoozed_row(858)],
                           timelines: { "858" => [DEFER] },
                           issues: { "858" => blocked_issue(858) })
    assert_empty writes
    assert_equal %w[858], result.skipped
  end

  def test_a_deferral_whose_fix_is_still_open_is_left_alone
    result, writes = sweep(rows: [snoozed_row(859)],
                           timelines: { "859" => [DEFER_COMMENT] },
                           issues: { "859" => blocked_issue(859) },
                           merged: [])
    assert_empty writes
    assert_equal %w[859], result.blocked
  end

  # ISS-1097, from this side. The merge is not the trigger — the RELEASE is, and
  # this is the pass that woke ISS-1024 four minutes before a session claimed it
  # and found workers#207 on main and 0.1.77 in production.
  def test_a_deferral_whose_fix_merged_but_has_not_been_released_is_left_alone
    result, writes = sweep(rows: [snoozed_row(1024)],
                           timelines: { "1024" => [DEFER_COMMENT] },
                           issues: { "1024" => blocked_issue(1024) },
                           released: false)
    assert_empty writes
    assert_equal %w[1024], result.blocked
  end

  # FAIL OPEN, pointed at "leave it alone". A rate-limited `gh` answers nil for
  # every url; read as `unshipped.empty?` that would unsnooze the whole fleet at
  # once, and the claims behind them would re-defer each one seconds later.
  def test_an_unreadable_github_leaves_every_deferral_in_place
    result, writes = sweep(rows: [snoozed_row(858), snoozed_row(859)],
                           timelines: { "858" => [DEFER_COMMENT], "859" => [DEFER_COMMENT] },
                           issues: { "858" => blocked_issue(858), "859" => blocked_issue(859) },
                           github_readable: false)
    assert_empty writes
    assert_equal %w[858 859], result.blocked
  end

  # An issue somebody else already woke — another runner's sweep, an expiry, a
  # human. The wake itself is idempotent server-side; the note beside it is not.
  def test_an_issue_that_is_no_longer_snoozed_is_not_commented_on_again
    _, writes = sweep(rows: [snoozed_row(858)],
                      timelines: { "858" => [DEFER_COMMENT] },
                      issues: { "858" => blocked_issue(858).merge("snoozed_until" => nil) })
    assert_empty writes
  end

  def test_nothing_is_written_on_a_dry_run
    result, writes = sweep(rows: [snoozed_row(858)],
                           timelines: { "858" => [DEFER_COMMENT] },
                           issues: { "858" => blocked_issue(858) },
                           dry_run: true)
    assert_empty writes
    assert_equal %w[858], result.woken, "a dry run still reports what it WOULD have woken"
  end

  # An issue whose record cannot be read is not woken on the strength of a
  # timeline alone — `cleared?` needs the blockers, and an issue with none reads
  # as vacuously cleared.
  def test_an_unreadable_issue_is_left_alone
    result, writes = sweep(rows: [snoozed_row(858)], timelines: { "858" => [DEFER_COMMENT] }, issue_error: true)
    assert_empty writes
    assert_empty result.woken
  end

  # An unreadable TIMELINE is the same answer for the same reason: not knowing
  # why an issue is snoozed is the case where leaving it snoozed is obviously
  # right.
  def test_an_unreadable_timeline_is_left_alone
    result, writes = sweep(rows: [snoozed_row(858)], timeline_error: true)
    assert_empty writes
    assert_empty result.woken
    assert_equal %w[858], result.skipped
  end

  # ---- a pass that cannot finish its writes ----

  # A Result that overstates what happened is how a silent failure gets reported
  # as a success — and the next pass five minutes later retries it anyway.
  def test_a_refused_wake_is_reported_rather_than_counted_as_woken
    result, = sweep(rows: [snoozed_row(858), snoozed_row(859)],
                    timelines: { "858" => [DEFER_COMMENT], "859" => [DEFER_COMMENT] },
                    issues: { "858" => blocked_issue(858), "859" => blocked_issue(859) },
                    wake_error: true)
    assert_empty result.woken
    assert_equal %w[858 859], result.failed, "one refusal must not cost the rest of the pass either"
  end

  # The wake landed; only the courtesy note did not. Reporting that as a failure
  # would be the sweep lying in the safe-looking direction about an issue that is
  # genuinely back in the queue.
  def test_a_wake_whose_note_failed_is_still_a_wake
    result, writes = sweep(rows: [snoozed_row(858)],
                           timelines: { "858" => [DEFER_COMMENT] },
                           issues: { "858" => blocked_issue(858) },
                           comment_error: true)
    assert_equal %w[858], result.woken
    assert_empty result.failed
    assert_equal [[:wake, "858"]], writes
  end

  # ---- waking too little: the bounds, and saying so ----

  def test_candidates_past_the_cap_are_reported_rather_than_dropped_in_silence
    rows = (1..5).map { |n| snoozed_row(900 + n) }
    result, = sweep(rows: rows, cap: 2)
    assert_equal 3, result.dropped
  end

  def test_a_full_page_is_reported_as_possibly_incomplete
    rows = (1..Agent::Api::ISSUES_PAGE_LIMIT).map { |n| snoozed_row(n) }
    result, = sweep(rows: rows, cap: 1)
    assert result.truncated
    refute sweep(rows: [snoozed_row(858)]).first.truncated
  end

  # ---- cadence ----

  def test_the_sweep_runs_on_a_few_minute_cadence_not_every_tick
    Dir.mktmpdir do |dir|
      file = File.join(dir, "dependency-wake.json")
      now = Time.utc(2026, 8, 8, 12, 0, 0)
      assert Agent::DependencyWake.due?(now: now, file: file), "a machine that has never swept is due immediately"
      Agent::DependencyWake.mark_swept(now: now, file: file)
      refute Agent::DependencyWake.due?(now: now + 30, file: file), "the tick's own 30 seconds is not the cadence"
      refute Agent::DependencyWake.due?(now: now + Agent::DependencyWake::SWEEP_INTERVAL_SECONDS - 1, file: file)
      assert Agent::DependencyWake.due?(now: now + Agent::DependencyWake::SWEEP_INTERVAL_SECONDS, file: file)
    end
  end

  # A corrupt or truncated stamp costs one extra pass, never a sweep that never
  # runs again.
  def test_an_unreadable_stamp_is_due
    Dir.mktmpdir do |dir|
      file = File.join(dir, "dependency-wake.json")
      File.write(file, "{ not json")
      assert Agent::DependencyWake.due?(now: Time.utc(2026, 8, 8), file: file)
      File.write(file, '{"at":"not a time"}')
      assert Agent::DependencyWake.due?(now: Time.utc(2026, 8, 8), file: file)
    end
  end

  # The cadence is well under the deferral it exists to shorten — the whole point
  # is that the wake stops being measured in days.
  def test_the_cadence_is_far_inside_the_deferral_it_shortens
    assert_operator Agent::DependencyWake::SWEEP_INTERVAL_SECONDS, :<,
                    Agent::Tick::DEPENDENCY_DEFER_DAYS * 24 * 60 * 60 / 10
  end
end
