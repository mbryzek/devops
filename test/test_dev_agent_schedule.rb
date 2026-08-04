#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The producer schedule grammar and its due-ness arithmetic. Pure functions, so
# they are tested directly rather than through a tick — this is the part where a
# quiet mistake means a producer runs 24 times a day, or once a year, and nothing
# looks wrong.
#
# The DST cases are the reason `timezone` is an IANA zone and not an offset.
class TestDevAgentSchedule < Minitest::Test
  include DevTestSupport

  ZONE = "America/New_York".freeze

  # ---- parsing ----

  def test_every_forms
    assert_equal({ kind: :every, seconds: 3600 }, Agent::Schedule.parse("every 1 hour"))
    assert_equal({ kind: :every, seconds: 1800 }, Agent::Schedule.parse("every 30 minutes"))
    assert_equal({ kind: :every, seconds: 172_800 }, Agent::Schedule.parse("every 2 days"))
  end

  def test_daily_forms
    assert_equal({ kind: :daily, hour: 3, minute: 0 }, Agent::Schedule.parse("daily at 3:00am"))
    assert_equal({ kind: :daily, hour: 16, minute: 30 }, Agent::Schedule.parse("daily at 4:30pm"))
    assert_equal({ kind: :daily, hour: 14, minute: 5 }, Agent::Schedule.parse("daily at 14:05"))
    # 12am is midnight, not noon — the one place a naive +12 gets it wrong.
    assert_equal({ kind: :daily, hour: 0, minute: 0 }, Agent::Schedule.parse("daily at 12:00am"))
    assert_equal({ kind: :daily, hour: 12, minute: 0 }, Agent::Schedule.parse("daily at 12:00pm"))
  end

  def test_weekly_form
    assert_equal({ kind: :weekly, wday: 1, hour: 2, minute: 0 }, Agent::Schedule.parse("weekly on monday at 2:00am"))
    assert_equal({ kind: :weekly, wday: 0, hour: 23, minute: 15 }, Agent::Schedule.parse("Weekly on Sunday at 11:15pm"))
  end

  def test_rejects_anything_outside_the_three_forms
    ["0 3 * * *", "every hour", "every 0 hours", "daily at 25:00", "daily at 3:99am",
     "weekly on caturday at 2:00am", "hourly", ""].each do |text|
      assert_raises(Agent::Schedule::ParseError, "expected #{text.inspect} to be rejected") do
        Agent::Schedule.parse(text)
      end
    end
  end

  # ---- due-ness: every ----

  def test_every_is_due_when_never_run
    assert Agent::Schedule.due?(Agent::Schedule.parse("every 1 hour"), last_run_at: nil, now: Time.now)
  end

  def test_every_waits_out_the_interval
    schedule = Agent::Schedule.parse("every 30 minutes")
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    refute Agent::Schedule.due?(schedule, last_run_at: now - 29 * 60, now: now)
    assert Agent::Schedule.due?(schedule, last_run_at: now - 30 * 60, now: now)
  end

  # ---- due-ness: daily / weekly ----

  def test_daily_is_due_once_per_local_day
    schedule = Agent::Schedule.parse("daily at 3:00am")
    now = Time.utc(2026, 8, 3, 12, 0, 0) # 08:00 EDT
    ran_today = Time.utc(2026, 8, 3, 7, 30, 0) # 03:30 EDT, after the 3am mark
    ran_yesterday = Time.utc(2026, 8, 2, 7, 30, 0)
    refute Agent::Schedule.due?(schedule, last_run_at: ran_today, now: now, timezone: ZONE)
    assert Agent::Schedule.due?(schedule, last_run_at: ran_yesterday, now: now, timezone: ZONE)
  end

  def test_daily_not_due_before_todays_mark
    schedule = Agent::Schedule.parse("daily at 3:00am")
    now = Time.utc(2026, 8, 3, 6, 0, 0) # 02:00 EDT — before 3am
    # Yesterday's 3am already ran, and today's has not arrived.
    refute Agent::Schedule.due?(schedule, last_run_at: Time.utc(2026, 8, 2, 7, 0, 0), now: now, timezone: ZONE)
  end

  def test_weekly_fires_on_its_day_only
    schedule = Agent::Schedule.parse("weekly on monday at 2:00am")
    monday_noon = Time.utc(2026, 8, 3, 16, 0, 0) # Mon 2026-08-03, 12:00 EDT
    ran_last_monday = Time.utc(2026, 7, 27, 6, 0, 0)
    assert Agent::Schedule.due?(schedule, last_run_at: ran_last_monday, now: monday_noon, timezone: ZONE)

    ran_this_monday = Time.utc(2026, 8, 3, 6, 30, 0) # 02:30 EDT today
    refute Agent::Schedule.due?(schedule, last_run_at: ran_this_monday, now: monday_noon, timezone: ZONE)

    # Wednesday: still not due again, because the last run covered this week's
    # Monday and the next occurrence has not arrived.
    wednesday = Time.utc(2026, 8, 5, 16, 0, 0)
    refute Agent::Schedule.due?(schedule, last_run_at: ran_this_monday, now: wednesday, timezone: ZONE)
  end

  # ---- DST: the reason the zone is IANA and not an offset ----
  #
  # America/New_York springs forward 2026-03-08 and falls back 2026-11-01. A
  # "daily at 3:00am" schedule must land on local 3:00am on both sides, which
  # means consecutive occurrences are 23 hours apart in March and 25 in November.
  # Fixed 86_400-second arithmetic would silently drift the schedule an hour
  # twice a year.

  def test_spring_forward_keeps_3am_local
    schedule = Agent::Schedule.parse("daily at 3:00am")
    after = Agent::Schedule.previous_occurrence(schedule, now: Time.utc(2026, 3, 8, 18, 0, 0), timezone: ZONE)
    before = Agent::Schedule.previous_occurrence(schedule, now: Time.utc(2026, 3, 7, 18, 0, 0), timezone: ZONE)

    assert_equal Time.utc(2026, 3, 8, 7, 0, 0), after,  "2026-03-08 03:00 EDT is 07:00 UTC"
    assert_equal Time.utc(2026, 3, 7, 8, 0, 0), before, "2026-03-07 03:00 EST is 08:00 UTC"
    assert_equal 23 * 3600, after - before, "spring forward: consecutive 3am marks are 23h apart"
  end

  def test_fall_back_keeps_3am_local
    schedule = Agent::Schedule.parse("daily at 3:00am")
    after = Agent::Schedule.previous_occurrence(schedule, now: Time.utc(2026, 11, 1, 18, 0, 0), timezone: ZONE)
    before = Agent::Schedule.previous_occurrence(schedule, now: Time.utc(2026, 10, 31, 18, 0, 0), timezone: ZONE)

    assert_equal Time.utc(2026, 11, 1, 8, 0, 0),  after,  "2026-11-01 03:00 EST is 08:00 UTC"
    assert_equal Time.utc(2026, 10, 31, 7, 0, 0), before, "2026-10-31 03:00 EDT is 07:00 UTC"
    assert_equal 25 * 3600, after - before, "fall back: consecutive 3am marks are 25h apart"
  end

  def test_dst_transition_does_not_double_fire_or_skip
    schedule = Agent::Schedule.parse("daily at 3:00am")
    # Ran at the spring-forward day's 3am. Later that same day it must not be due
    # again, and the next day it must be.
    ran = Time.utc(2026, 3, 8, 7, 0, 0)
    refute Agent::Schedule.due?(schedule, last_run_at: ran, now: Time.utc(2026, 3, 8, 20, 0, 0), timezone: ZONE)
    assert Agent::Schedule.due?(schedule, last_run_at: ran, now: Time.utc(2026, 3, 9, 8, 0, 0), timezone: ZONE)
  end

  # in_zone scopes an ENV mutation, and a leak would silently reinterpret every
  # later timestamp in the tick.
  def test_timezone_is_restored_after_evaluation
    original = ENV["TZ"]
    schedule = Agent::Schedule.parse("daily at 3:00am")
    ["UTC", nil].each do |ambient|
      ENV["TZ"] = ambient
      Agent::Schedule.due?(schedule, last_run_at: nil, now: Time.now, timezone: ZONE)
      assert_equal ambient.inspect, ENV["TZ"].inspect, "TZ leaked (ambient #{ambient.inspect})"
    end
  ensure
    ENV["TZ"] = original
  end

  def test_next_due_moves_forward
    schedule = Agent::Schedule.parse("daily at 3:00am")
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    ran_today = Time.utc(2026, 8, 3, 7, 30, 0)
    assert_equal Time.utc(2026, 8, 4, 7, 0, 0),
                 Agent::Schedule.next_due(schedule, last_run_at: ran_today, now: now, timezone: ZONE)
  end

  def test_describe_round_trips_the_spoken_form
    ["every 1 hour", "every 30 minutes", "daily at 03:00", "weekly on monday at 02:00"].each do |text|
      assert_equal text, Agent::Schedule.describe(Agent::Schedule.parse(text))
    end
  end

  # ---- period_start: the arbitration guard ----
  #
  # The platform declines a run when one already exists with
  # `started_at >= if_no_run_since`. That comparison is INCLUSIVE, so the guard
  # must be the start of the current period and never the previous run's own
  # `started_at` — a run is always `>=` itself, and passing it made every
  # producer block itself forever after its first run (one tick claimed and then
  # `issue-reconcile` was declined on 19 consecutive ticks with nothing in
  # flight). The single assertion that catches it: strictly AFTER the last run.

  def test_period_start_for_an_interval_is_strictly_after_the_last_run
    schedule = Agent::Schedule.parse("every 30 minutes")
    last = Time.utc(2026, 8, 4, 16, 57, 29)
    boundary = Agent::Schedule.period_start(schedule, last_run_at: last, now: Time.utc(2026, 8, 4, 17, 36, 0))

    assert_equal Time.utc(2026, 8, 4, 17, 27, 29), boundary
    assert boundary > last, "the guard must never be the previous run's own start time"
  end

  def test_period_start_is_nil_when_a_producer_has_never_run
    # No prior period to sit inside; the platform then applies only its
    # in-flight check, which is what lets a brand new producer run at all.
    assert_nil Agent::Schedule.period_start(Agent::Schedule.parse("every 1 hour"),
                                            last_run_at: nil, now: Time.utc(2026, 8, 4, 17, 0, 0))
  end

  def test_period_start_for_a_wall_clock_schedule_is_the_occurrence_not_the_last_run
    schedule = Agent::Schedule.parse("daily at 3:00am")
    now = Time.utc(2026, 8, 4, 12, 0, 0)              # 08:00 America/New_York
    yesterday = Time.utc(2026, 8, 3, 7, 0, 30)        # yesterday's 03:00 run

    boundary = Agent::Schedule.period_start(schedule, last_run_at: yesterday, now: now, timezone: ZONE)

    assert_equal Time.utc(2026, 8, 4, 7, 0, 0), boundary
    assert boundary > yesterday, "today's occurrence must not be blocked by yesterday's run"
  end

  def test_period_start_still_excludes_a_run_already_made_this_period
    # The guard has to keep doing its actual job: a second machine that already
    # ran this period's job must still be declined, which is what `>=` gives us
    # once the boundary is the period start.
    schedule = Agent::Schedule.parse("every 30 minutes")
    last = Time.utc(2026, 8, 4, 16, 57, 29)
    boundary = Agent::Schedule.period_start(schedule, last_run_at: last, now: Time.utc(2026, 8, 4, 17, 30, 0))
    ran_this_period = Time.utc(2026, 8, 4, 17, 27, 40)

    assert ran_this_period >= boundary, "a run inside the current period must still block a second one"
  end
  # ---- the reported registry (ISS-392) ----
  #
  # `Agent::Producers.report` is the whole reason the platform can show "should
  # have run and did not" without ever learning the schedule grammar: the
  # arithmetic happens here and only a conclusion crosses the wire.

  def registry(*producers)
    entries = producers.map do |key, schedule|
      { "key" => key, "schedule" => schedule, "check" => "true", "file_when" => "check_fails",
        "issue" => { "title" => key, "category" => "infrastructure", "fingerprint" => "fp:#{key}" } }
    end
    Agent::Producers.parse({ "timezone" => ZONE, "producers" => entries }.to_yaml)
  end

  def test_report_carries_the_authored_schedule_text_and_a_computed_next_due
    now = Time.utc(2026, 8, 4, 12, 0, 0)
    last = { "hourly" => Time.utc(2026, 8, 4, 11, 30, 0) }

    entry = Agent::Producers.report(registry(["hourly", "every 1 hour"]), last_run_by_key: last, now: now).first

    assert_equal "hourly", entry[:producer_key]
    # The text as authored, not a re-rendering of the parsed form: two runners on
    # different devops shas are meant to be comparable by eye.
    assert_equal "every 1 hour", entry[:schedule]
    assert_equal "2026-08-04T12:30:00Z", entry[:next_due_at]
  end

  # A producer that has never run is due NOW, not at the next wall-clock
  # occurrence — the same rule `due?` uses, so admin cannot disagree with the
  # tick about what is overdue.
  def test_report_marks_a_producer_that_has_never_run_as_due_now
    now = Time.utc(2026, 8, 4, 12, 0, 0)
    entry = Agent::Producers.report(registry(["nightly", "daily at 3:00am"]), last_run_by_key: {}, now: now).first
    assert_equal "2026-08-04T12:00:00Z", entry[:next_due_at]
  end

  def test_report_covers_every_producer_in_registry_order
    now = Time.utc(2026, 8, 4, 12, 0, 0)
    entries = Agent::Producers.report(registry(["a", "every 1 hour"], ["b", "daily at 3:00am"]),
                                      last_run_by_key: {}, now: now)
    assert_equal %w[a b], entries.map { |e| e[:producer_key] }
  end
end
