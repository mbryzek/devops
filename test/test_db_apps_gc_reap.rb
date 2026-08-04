#!/usr/bin/env ruby
require 'minitest/autorun'
require 'set'
require_relative '../lib/common'
require_relative 'test_helper'

# gc reaps on AGE. The rule it replaced — "drop every session database with no
# backend connected right now" — treated a session sitting between test runs as
# dead, which is the normal state of a working session: on 2026-08-04, 11 live
# sessions held ~60 databases and pg_stat_activity was empty for every single
# one, so one `gc` would have destroyed all of them.
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

  def reap(dbs, active: [], ages: {}, cutoff: 3 * DAY, current_db: nil)
    app.reapable_session_dbs(
      dbs, :active => active.to_set, :ages => ages,
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
    a.stub(:sess_prefix, "platformdb_sess_") do
      DbImages.stub(:psql_query, ["platformdb_sess_a|345600", "platformdb_sess_b|60"]) do
        assert_equal({ "platformdb_sess_a" => 345_600, "platformdb_sess_b" => 60 },
                     a.session_db_ages(5432))
      end
    end
  end

  # A failed query returns no rows, which must yield "no ages known" (keep
  # everything), not an exception and not a silent empty-means-reap.
  def test_session_db_ages_is_empty_when_the_query_fails
    DbImages.stub(:psql_query, []) do
      assert_empty app.session_db_ages(5432)
    end
  end

  def test_session_db_ages_skips_malformed_rows
    DbImages.stub(:psql_query, ["platformdb_sess_ok|100", "garbage-no-separator", "platformdb_sess_x|"]) do
      assert_equal({ "platformdb_sess_ok" => 100 }, app.session_db_ages(5432))
    end
  end
end
