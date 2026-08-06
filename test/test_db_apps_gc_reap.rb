#!/usr/bin/env ruby
require 'minitest/autorun'
require 'set'
require_relative '../lib/common'
require_relative 'test_helper'

# gc reaps a session database only once BOTH ages agree it is finished: it was
# created before the cutoff, and it has had no activity since.
#
# Each of those on its own has already been tried and has already destroyed live
# sessions' work. "No backend connected right now" treated a session sitting
# between test runs as dead, which is the normal state of a working session: on
# 2026-08-04, 11 live sessions held ~60 databases and pg_stat_activity was empty
# for every single one, so one `gc` would have destroyed all of them. Creation
# age replaced it and reaps a session that is STILL RUNNING past the cutoff,
# which a multi-day feature legitimately is (ISS-583).
#
# Every test here is a case where getting the predicate wrong deletes another
# session's work, so the bias is pinned in one direction: when in doubt, KEEP.
class TestDbAppsGcReap < Minitest::Test
  include DevTestSupport

  DAY = 86_400

  def app
    DbApp.new(:name => "platform", :database => "platformdb", :role => "api",
              :repo_dir => "/tmp/platform-postgresql")
  end

  # `idle` defaults to `ages` — a database never used since the moment it was
  # created, which is what every test written against the creation-age-only rule
  # was implicitly describing. Tests about the last-used signal pass it.
  def reap(dbs, active: [], ages: {}, idle: nil, cutoff: 3 * DAY, current_db: nil)
    app.reapable_session_dbs(
      dbs, :active => active.to_set, :ages => ages, :idle => idle || ages,
      :cutoff_seconds => cutoff, :current_db => current_db
    )
  end

  # ── age is the criterion ──────────────────────────────────────────────────

  def test_drops_databases_older_than_the_cutoff
    ages = { "platformdb_sess_old" => 4 * DAY }
    assert_equal ["platformdb_sess_old"], reap(["platformdb_sess_old"], :ages => ages)
  end

  def test_keeps_databases_younger_than_the_cutoff
    ages = { "platformdb_sess_new" => 2 * DAY }
    assert_empty reap(["platformdb_sess_new"], :ages => ages)
  end

  def test_cutoff_is_inclusive_at_exactly_the_boundary
    ages = { "platformdb_sess_edge" => 3 * DAY }
    assert_equal ["platformdb_sess_edge"], reap(["platformdb_sess_edge"], :ages => ages)
  end

  def test_days_zero_reaps_everything_idle
    ages = { "platformdb_sess_a" => 0, "platformdb_sess_b" => 10 }
    assert_equal ["platformdb_sess_a", "platformdb_sess_b"],
                 reap(["platformdb_sess_a", "platformdb_sess_b"], :ages => ages, :cutoff => 0)
  end

  # ── the regression this change exists to prevent ──────────────────────────

  # The exact 2026-08-04 shape: many old-ish databases, nothing connected. Under
  # the old rule every one of these was an "orphan"; under age, only the old ones go.
  def test_idle_but_recent_databases_survive_a_gc_with_no_connections_anywhere
    ages = {
      "platformdb_sess_autonomy_ledger" => 2 * DAY, # live session, just idle
      "platformdb_sess_test_speedup"    => 4 * DAY, # genuinely abandoned
    }
    assert_equal ["platformdb_sess_test_speedup"],
                 reap(ages.keys, :active => [], :ages => ages)
  end

  # ── the regression THIS change exists to prevent (ISS-583) ────────────────

  # A session that has been running for a week and used its database an hour
  # ago. Under creation age alone this was reaped by anybody else's gc the
  # moment it happened to be idle at the sampling instant — which is the normal
  # state of a session between test runs, and the exact failure creation age was
  # introduced to fix, one time unit up.
  def test_keeps_an_old_database_that_is_still_being_used
    assert_empty reap(["platformdb_sess_multi_day"],
                      :ages => { "platformdb_sess_multi_day" => 9 * DAY },
                      :idle => { "platformdb_sess_multi_day" => 3600 })
  end

  def test_drops_an_old_database_that_has_not_been_used
    assert_equal ["platformdb_sess_abandoned"],
                 reap(["platformdb_sess_abandoned"],
                      :ages => { "platformdb_sess_abandoned" => 9 * DAY },
                      :idle => { "platformdb_sess_abandoned" => 5 * DAY })
  end

  # Both ages gate every reap, so the last-used signal can only ever RESCUE a
  # database creation age would have taken — never condemn one it would have
  # kept. A stale or wrong ledger row therefore cannot cost anybody their work.
  def test_a_long_unused_reading_cannot_reap_a_database_created_inside_the_cutoff
    assert_empty reap(["platformdb_sess_young"],
                      :ages => { "platformdb_sess_young" => 1 * DAY },
                      :idle => { "platformdb_sess_young" => 9 * DAY })
  end

  # The ledger lives in the container, so a container predating this change — or
  # one whose ledger query failed — reports nothing. That has to keep the
  # database, not fall back to reaping it on creation age alone.
  def test_keeps_a_database_whose_last_use_could_not_be_read
    assert_empty reap(["platformdb_sess_unseen"],
                      :ages => { "platformdb_sess_unseen" => 9 * DAY },
                      :idle => {})
  end

  # ── independent guards ────────────────────────────────────────────────────

  def test_keeps_an_active_database_however_old
    ages = { "platformdb_sess_busy" => 99 * DAY }
    assert_empty reap(["platformdb_sess_busy"], :active => ["platformdb_sess_busy"], :ages => ages)
  end

  def test_keeps_the_current_sessions_database_however_old
    ages = { "platformdb_sess_mine" => 99 * DAY }
    assert_empty reap(["platformdb_sess_mine"], :ages => ages, :current_db => "platformdb_sess_mine")
  end

  # An unreadable age must not be treated as "infinitely old". If pg_stat_file
  # ever fails, gc has to degrade into doing nothing, not into dropping everything.
  def test_keeps_a_database_whose_age_could_not_be_read
    assert_empty reap(["platformdb_sess_unknown"], :ages => {})
  end

  def test_missing_ages_do_not_block_reaping_the_ones_we_can_read
    ages = { "platformdb_sess_known" => 5 * DAY }
    assert_equal ["platformdb_sess_known"],
                 reap(["platformdb_sess_known", "platformdb_sess_unknown"], :ages => ages)
  end

  # ── no session id required ────────────────────────────────────────────────

  # gc must run from ~/code, where no session id can be derived. current_db is
  # then nil, and nil must not accidentally match a database name.
  def test_nil_current_db_still_reaps_normally
    ages = { "platformdb_sess_old" => 5 * DAY }
    assert_equal ["platformdb_sess_old"], reap(["platformdb_sess_old"], :ages => ages, :current_db => nil)
  end

  # ── age parsing ───────────────────────────────────────────────────────────

  def test_session_db_ages_parses_name_and_seconds
    a = app
    stub_singleton(a, :sess_prefix, ->(*) { "platformdb_sess_" }) do
      stub_singleton(DbImages, :psql_query, ->(*) { ["platformdb_sess_a|345600", "platformdb_sess_b|60"] }) do
        assert_equal({ "platformdb_sess_a" => 345_600, "platformdb_sess_b" => 60 },
                     a.session_db_ages(5432))
      end
    end
  end

  # A failed query returns no rows, which must yield "no ages known" (keep
  # everything), not an exception and not a silent empty-means-reap.
  def test_session_db_ages_is_empty_when_the_query_fails
    stub_singleton(DbImages, :psql_query, ->(*) { [] }) do
      assert_empty app.session_db_ages(5432)
    end
  end

  def test_session_db_ages_skips_malformed_rows
    stub_singleton(DbImages, :psql_query,
                   ->(*) { ["platformdb_sess_ok|100", "garbage-no-separator", "platformdb_sess_x|"] }) do
      assert_equal({ "platformdb_sess_ok" => 100 }, app.session_db_ages(5432))
    end
  end

  # ── the last look before the drop ─────────────────────────────────────────
  #
  # `active` is sampled ONCE per container, and gc then walks that container's
  # whole stale list dropping databases one at a time. Everything in between is
  # time a session had to reconnect to a database already judged idle -- and gc
  # does not lose that race politely, it pg_terminate_backend()s first, so the
  # reconnected session has its connection killed and its database destroyed
  # under it.
  #
  # Same bias as every other test in this file: when in doubt, KEEP.

  def test_a_database_that_woke_up_since_the_scan_reads_as_active
    stub_singleton(DbImages, :psql_query, ->(*) { ["1"] }) do
      assert app.session_db_active?(5432, "platformdb_sess_awake")
    end
  end

  def test_an_idle_database_reads_as_inactive
    stub_singleton(DbImages, :psql_query, ->(*) { [] }) do
      refute app.session_db_active?(5432, "platformdb_sess_idle")
    end
  end

  # The check asks about ONE database, not the prefix -- a sibling session's
  # connection must not spare an unrelated database (nor the reverse).
  def test_the_recheck_is_scoped_to_the_one_database
    seen = nil
    stub_singleton(DbImages, :psql_query, ->(_port, sql, **_o) { seen = sql; [] }) do
      app.session_db_active?(5432, "platformdb_sess_target")
    end
    assert_includes seen, "datname = 'platformdb_sess_target'"
    refute_includes seen, "LIKE"
  end

  # A failed psql returns no rows. That reads as "not active", which drops --
  # the one place in this file where the fallback is not "keep". It is the right
  # call: this is a SECOND look, and the first one (active_session_dbs, which
  # fails the same way) already had to say the database was idle. Treating a
  # failed re-check as active would make an unreachable psql mean nothing is
  # ever reaped.
  def test_a_failed_recheck_does_not_block_the_drop
    stub_singleton(DbImages, :psql_query, ->(*) { [] }) do
      refute app.session_db_active?(5432, "platformdb_sess_x")
    end
  end

  # ── folding a connection-count sample into "how long unused" ──────────────
  #
  # The count is monotonic, so equality across two observations means nothing
  # connected over the WHOLE interval between them, however long. That is what
  # makes the answer independent of how often anybody happens to run gc — the
  # property the pg_stat_activity test lacked.

  def sample(connects:, recorded: nil, idle: nil)
    { "connects" => connects, "recorded" => recorded, "idle" => idle }
  end

  def reconcile(activity, active: [])
    DbApp.reconcile_activity(activity, :active => active.to_set)
  end

  def test_a_moved_counter_stamps_the_database_as_used_now
    idle, stamps = reconcile({ "db" => sample(:connects => 900, :recorded => 700, :idle => 5 * DAY) })
    assert_equal({ "db" => 0 }, idle)
    assert_equal({ "db" => 900 }, stamps)
  end

  def test_an_unmoved_counter_keeps_the_recorded_idle_time_and_rewrites_nothing
    idle, stamps = reconcile({ "db" => sample(:connects => 700, :recorded => 700, :idle => 5 * DAY) })
    assert_equal({ "db" => 5 * DAY }, idle)
    assert_empty stamps
  end

  # A database nobody has observed yet is stamped NOW, not at its creation time.
  # That buys every database one full cutoff window the first time it is seen —
  # including every database already on the box when this shipped, about which
  # no honest claim can be made. It costs one delayed reap per database, once.
  def test_first_sight_stamps_now_rather_than_inheriting_creation_age
    idle, stamps = reconcile({ "db" => sample(:connects => 12) })
    assert_equal({ "db" => 0 }, idle)
    assert_equal({ "db" => 12 }, stamps)
  end

  # A postmaster crash resets pg_stat_database to zero. A counter that went
  # BACKWARDS is therefore not "no activity" — it is a stats epoch this ledger
  # row cannot speak for, and the safe reading is to start again from now.
  def test_a_counter_that_went_backwards_is_treated_as_activity_not_as_stillness
    idle, stamps = reconcile({ "db" => sample(:connects => 3, :recorded => 90_000, :idle => 9 * DAY) })
    assert_equal({ "db" => 0 }, idle)
    assert_equal({ "db" => 3 }, stamps)
  end

  # Not redundant with the counter: a pooled connection held open across a long
  # idle stretch moves no counter at all, and a session holding one is alive.
  def test_a_live_connection_stamps_the_database_even_with_an_unmoved_counter
    idle, stamps = reconcile({ "db" => sample(:connects => 700, :recorded => 700, :idle => 9 * DAY) },
                             :active => ["db"])
    assert_equal({ "db" => 0 }, idle)
    assert_equal({ "db" => 700 }, stamps)
  end

  # ── reading the ledger ────────────────────────────────────────────────────

  def test_session_db_activity_parses_live_and_recorded_columns
    rows = ["platformdb_sess_a|900|700|432000", "platformdb_sess_b|12||"]
    stub_singleton(DbImages, :psql_query, ->(*) { rows }) do
      assert_equal({
                     "platformdb_sess_a" => { "connects" => 900, "recorded" => 700, "idle" => 432_000 },
                     "platformdb_sess_b" => { "connects" => 12, "recorded" => nil, "idle" => nil }
                   }, app.session_db_activity(5432))
    end
  end

  # A container that predates the ledger table has no table for the query to
  # join against, so psql errors and psql_query hands back nothing. That has to
  # read as "no last-used signal" — which reapable_session_dbs keeps — rather
  # than as "used never".
  def test_session_db_activity_is_empty_when_the_query_fails
    stub_singleton(DbImages, :psql_query, ->(*) { [] }) do
      assert_empty app.session_db_activity(5432)
    end
  end

  def test_session_db_activity_skips_rows_with_no_live_counter
    stub_singleton(DbImages, :psql_query, ->(*) { ["platformdb_sess_x||700|60", "no-separators"] }) do
      assert_empty app.session_db_activity(5432)
    end
  end

  # ── writing the ledger ────────────────────────────────────────────────────

  def recorded_sql(counts, keep:, stamp: true)
    captured = nil
    stub_singleton(DbImages, :psql_exec_quiet, ->(_port, sql) { captured = sql; true }) do
      app.record_session_db_activity(5432, counts, :keep => keep, :stamp => stamp)
    end
    captured
  end

  def test_recording_upserts_the_stamped_databases
    sql = recorded_sql({ "platformdb_sess_a" => 900 }, :keep => ["platformdb_sess_a"])
    assert_includes sql, "('platformdb_sess_a', 900, now())"
    assert_includes sql, "ON CONFLICT (datname) DO UPDATE"
    assert_includes sql, "seen_at = EXCLUDED.seen_at"
  end

  # claude-db's own connections move the same counter a session's do, and
  # `status` opens two per database. Recording them WITHOUT moving the stamp is
  # what stops one `status` from reading to the next gc as activity everywhere
  # and handing every database another cutoff window — which would switch gc off
  # by the act of looking at it.
  def test_absorbing_our_own_connections_records_the_count_and_leaves_the_stamp
    sql = recorded_sql({ "platformdb_sess_a" => 902 }, :keep => ["platformdb_sess_a"], :stamp => false)
    assert_includes sql, "connects = EXCLUDED.connects"
    assert_includes sql, "seen_at = #{DbApp::ACTIVITY_TABLE}.seen_at"
    refute_includes sql, "seen_at = EXCLUDED.seen_at"
  end

  # A database that is gone takes its ledger row with it, so a later database
  # that happens to reuse the name cannot inherit a stranger's last-used time.
  def test_recording_forgets_rows_for_databases_that_no_longer_exist
    sql = recorded_sql({ "platformdb_sess_a" => 900 }, :keep => ["platformdb_sess_a"])
    assert_includes sql, "DELETE FROM #{DbApp::ACTIVITY_TABLE}"
    assert_includes sql, "AND datname NOT IN ('platformdb_sess_a')"
  end

  def test_recording_an_empty_container_clears_every_row_and_inserts_nothing
    sql = recorded_sql({}, :keep => [])
    assert_includes sql, "DELETE FROM #{DbApp::ACTIVITY_TABLE} WHERE datname LIKE 'platformdb_sess_%'"
    refute_includes sql, "NOT IN"
    refute_includes sql, "INSERT"
  end

  # These names are interpolated into SQL rather than bound, so the shape of a
  # legal name is enforced rather than assumed — session_db_name sanitises them,
  # and anything that did not come from there is dropped instead of quoted in.
  def test_recording_drops_names_that_are_not_plain_identifiers
    sql = recorded_sql({ "bad'; DROP DATABASE platformdb_sess_a; --" => 1 },
                       :keep => ["bad'; DROP DATABASE platformdb_sess_a; --"])
    refute_includes sql, "DROP DATABASE"
    refute_includes sql, "INSERT"
  end
end
