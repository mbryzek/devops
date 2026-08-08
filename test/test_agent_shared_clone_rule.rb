#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/paths'
require 'session_db'

# The shared clone on `:5432` is READABLE and never WRITABLE, and the two halves
# of that have to move together.
#
# History, because the wording here is the whole point. §3 said "Never touch the
# production database, and never `:5432`" from ebdff0f (ISS-282) until ISS-1030,
# flat and unqualified — while the `slow-query-review` playbook told every session
# running it to `EXPLAIN` against exactly that database, calling itself "the one
# deliberate exception to the session-DB rule". Both documents read as
# authoritative and neither cited the other, so a session assigned index work had
# no correct move: the ISS-1021 run honoured §3, spent an hour rebuilding a
# 431,329-row fixture with nothing to calibrate against, and got its first
# baseline wrong by a factor of 3.6 (6,836 blocks against production's 24,566).
#
# Mike's decision on ISS-1030 narrowed the rule to what its own rationale
# supported — parallel sessions *clobber* a shared database, and clobbering is a
# write. So this file guards a pair, not a sentence:
#
#   the PERMISSION  §3 says reads are allowed, so a session may get a real plan
#                   instead of guessing at one. Without this half the playbook
#                   contradicts the guardrail again and ISS-1030 refiles itself.
#   the BOUNDARY    §3 says writes are not, including reverted ones, and nothing
#                   that RUNS points there. Without this half the permission
#                   drifts back into `CREATE INDEX` on Mike's database, which is
#                   the behaviour ISS-504 rejected.
#
# And the boundary's enforcement, `SessionDb.shared_default_url?`, is asserted
# from here rather than only from its own suite: a read permission written into
# §3 is safe precisely because no test suite, sbt run or app can reach `:5432`,
# and a change that quietly dropped the port check would leave §3's prose
# describing a guarantee nothing supplies.
class TestAgentSharedCloneRule < Minitest::Test
  # Read per call rather than memoized into an ivar: minitest inspects `self` on
  # a failure, and a 10KB ivar buries the assertion that failed.
  def instructions
    File.read(Agent::Paths.instructions_file)
  end

  def not_relaxed_section
    section = instructions[/^## 3\. What is NOT relaxed.*?^## 4\./m]
    refute_nil section, "instructions.md no longer has a §3 / §4 to place the rule between"
    section
  end

  # Asserts on a boolean rather than with assert_match, which prints the whole
  # haystack: §3 is several KB of prose, and a failure that buries its own
  # message under the section it was reading is a failure nobody reads.
  def assert_section_says(pattern, why)
    assert not_relaxed_section.match?(pattern), "agent/instructions.md §3: #{why} (looked for #{pattern.inspect})"
  end

  # ---- production, which did NOT get narrowed --------------------------------

  # ISS-1030 narrowed one of the two rules that shared a bullet. The other one is
  # unchanged and absolute, and the risk of splitting them is that the softer
  # wording bleeds onto the harder rule.
  def test_production_is_still_absolutely_off_limits
    assert_section_says(/Never touch the production database/,
                        "the production prohibition is gone from the not-relaxed section")
    assert_section_says(/no connection, no read, nothing/i,
                        "production must be stated as admitting no read at all — `:5432` now does, " \
                        "and the difference between them is the entire point of the bullet")
  end

  # ---- the permission --------------------------------------------------------

  def test_reads_on_the_shared_clone_are_permitted
    assert_section_says(/`SELECT` and `EXPLAIN`/,
                        "§3 no longer names the two statements a session may run against `:5432`. " \
                        "The slow-query-review playbook is built on this permission; without it that " \
                        "playbook contradicts its own guardrail again (ISS-1030)")
  end

  # A bare permission invites the next rewrite to trim it back as an
  # inconsistency. The reason it exists is that a fixture with nothing to
  # calibrate against produces an unverifiable baseline.
  def test_the_permission_states_why_it_exists
    assert_section_says(/ISS-1030/, "the decision that granted the read permission is no longer cited")
    assert_section_says(/calibrate/i,
                        "§3 no longer says WHY reads are permitted — that a reconstructed fixture with " \
                        "nothing to check it against ships a baseline nobody can trust (ISS-1021)")
  end

  # ---- the boundary ----------------------------------------------------------

  def test_writes_to_the_shared_clone_are_forbidden
    assert_section_says(/Never WRITE to `:5432`/,
                        "the write prohibition is gone — a read permission with no stated boundary is " \
                        "how `CREATE INDEX` on Mike's database comes back (ISS-504)")
  end

  # The failure ISS-504 was filed for was not a session ignoring the rule. It was
  # a session obeying "no writes" while reading `ANALYZE` and `SET STATISTICS` as
  # measurement rather than as writes, reverting them, and disclosing it
  # accurately. Naming the catalog statements is what closes that reading.
  def test_the_boundary_covers_catalog_writes_and_reverted_ones
    assert_section_says(/even when you intend to revert it/i,
                        "§3 must refuse writes a session plans to undo — `revert it carefully` holds " \
                        "only while the session survives to run the revert (ISS-504)")
    %w[ANALYZE VACUUM].each do |statement|
      assert_section_says(/#{statement}/,
                          "§3 no longer names #{statement} as a write. A session that reads catalog " \
                          "statements as measurement rather than as writes is exactly ISS-504")
    end
    assert_section_says(/CREATE INDEX/,
                        "§3 must name index creation as a write — it is the specific step ISS-1030 " \
                        "moved off the shared clone and into the session database")
  end

  # `EXPLAIN ANALYZE` is the one statement that looks like the permission and is
  # not covered by it. Nothing about "reads are allowed, writes are not" tells a
  # session that ANALYZE executes what it is planning.
  def test_the_explain_analyze_hazard_is_stated
    assert_section_says(/EXPLAIN ANALYZE.*EXECUTES/mi,
                        "§3 no longer warns that `EXPLAIN ANALYZE` runs the statement. It is a read " \
                        "only when the statement is a SELECT, and no amount of wording elsewhere " \
                        "makes that true of an UPDATE")
  end

  # The permission is for a human-driven psql session, not for pointing the app
  # at the clone. This is the sentence that keeps a read permission from being
  # read as "so CONF_DB_DEV_URL may name it now".
  def test_nothing_that_runs_may_point_at_the_shared_clone
    assert_section_says(/CONF_DB_DEV_URL/,
                        "§3 must say that the read permission does not extend to CONF_DB_DEV_URL — " \
                        "a suite pointed at `:5432` truncates Mike's tables")
    assert_section_says(/shared_default_url\?/,
                        "§3 should name the check that enforces this, so the prose and the code are " \
                        "findable from each other")
  end

  # ---- the fact the boundary rests on ----------------------------------------

  # Asserted here, and not only in test_session_db.rb, for the reason at the top:
  # §3's read permission is safe BECAUSE nothing that writes can reach the port.
  # A change that dropped this check would pass that file's other tests while
  # making §3's prose describe a guarantee nothing supplies.
  def test_the_port_check_still_refuses_the_shared_database
    assert SessionDb.shared_default_url?("jdbc:postgresql://localhost:5432/platformdb"),
           "SessionDb no longer recognises `:5432` as the shared database. agent/instructions.md §3 " \
           "permits sessions to READ that database precisely because nothing that runs can reach it — " \
           "re-read the rule before removing this."
    assert SessionDb.shared_default_url?("jdbc:postgresql://localhost/platformdb"),
           "a URL with no port is `:5432` too, however the host is spelled"
    refute SessionDb.shared_default_url?("jdbc:postgresql://localhost:5544/platformdb"),
           "an allocated session port must not be mistaken for the shared database"
  end

  def test_a_run_against_the_shared_database_is_still_blocked
    env = { "CLAUDECODE" => "1", "CONF_DB_DEV_URL" => "jdbc:postgresql://localhost:5432/platformdb" }
    assert_equal :shared, SessionDb.blocking_reason(:sbt_args => ["test"], :env => env),
                 "sbt pointed at `:5432` must still be refused. §3 grants a READ permission and " \
                 "explicitly withholds it from anything that runs; this is what withholds it."
  end
end
