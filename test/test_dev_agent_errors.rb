#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Errors: the bounded, on-disk error log a one-shot tick uses to know
# how many times in a row a source has failed, across process boundaries.
class TestDevAgentErrors < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |root|
      previous = ENV["DEV_AGENT_STATE_DIR"]
      ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
      yield
    ensure
      ENV["DEV_AGENT_STATE_DIR"] = previous
    end
  end

  def test_starts_empty
    with_state_dir { assert_empty Agent::Errors.list }
  end

  def test_record_appends_and_count_derives_from_the_list
    with_state_dir do
      Agent::Errors.record("checkout_pull", "one", now: Time.utc(2026, 8, 5, 10))
      Agent::Errors.record("checkout_pull", "two", now: Time.utc(2026, 8, 5, 10, 1))
      assert_equal 2, Agent::Errors.count("checkout_pull")
      assert_equal ["one", "two"], Agent::Errors.list.map { |e| e["message"] }
    end
  end

  def test_clear_removes_only_the_named_source
    with_state_dir do
      Agent::Errors.record("checkout_pull", "a", now: Time.now)
      Agent::Errors.record("other_source", "b", now: Time.now)
      Agent::Errors.clear("checkout_pull")
      assert_equal 0, Agent::Errors.count("checkout_pull")
      assert_equal 1, Agent::Errors.count("other_source")
    end
  end

  # Capped PER SOURCE, that source's oldest evicted first — a source that never
  # recovers must not grow this file without bound.
  def test_capped_per_source_oldest_of_that_source_evicted_first
    with_state_dir do
      7.times { |i| Agent::Errors.record("checkout_pull", "err#{i}", now: Time.now) }
      entries = Agent::Errors.list
      assert_equal Agent::Errors::PER_SOURCE_CAP, entries.length
      assert_equal %w[err2 err3 err4 err5 err6], entries.map { |e| e["message"] }
    end
  end

  # ISS-742, and the whole point of the per-source cap: what a source's count
  # means must not depend on how many OTHER sources are failing beside it. One
  # tick runs every chore, so the real machine produces exactly this round-robin
  # — and under the old total cap of 10 the count for each of six sources topped
  # out at 1, so Agent::Tick::ERROR_ESCALATE_AT was unreachable on the most
  # broken machine in the fleet.
  SIX_SOURCES = %w[checkout_pull claude_config agent_gc aidirs_prune claude_db_gc docker_prune].freeze

  def test_a_streak_is_unaffected_by_every_other_source_failing_in_the_same_round
    with_state_dir do
      counts_at_each_round = []
      4.times do
        SIX_SOURCES.each { |source| Agent::Errors.record(source, "boom", now: Time.now) }
        counts_at_each_round << SIX_SOURCES.map { |source| Agent::Errors.count(source) }
      end
      assert_equal [[1] * 6, [2] * 6, [3] * 6, [4] * 6], counts_at_each_round,
                   "every source must count its own failures, whatever its neighbours did"
    end
  end

  # A count that saturated AT the escalation threshold would satisfy the tick's
  # `count == ERROR_ESCALATE_AT` on every tick forever, re-notifying and
  # re-filing for a streak that was already escalated. Strictly greater is what
  # makes the crossing check a crossing.
  def test_a_streak_keeps_climbing_past_the_escalation_threshold
    with_state_dir do
      counts = (1..7).map do
        Agent::Errors.record("docker_prune", "boom", now: Time.now)
        Agent::Errors.count("docker_prune")
      end
      assert_equal [1, 2, 3, 4, 5, 5, 5], counts
    end
  end

  # The bound the old total cap was there for, kept: a per-source cap alone
  # bounds this file only while every caller passes one of a fixed set of
  # sources. Sources go WHOLE, least recently failed first — trimming a
  # surviving source's oldest row is the bug this file just fixed.
  def test_sources_are_evicted_whole_once_max_sources_is_exceeded
    with_state_dir do
      (Agent::Errors::MAX_SOURCES + 1).times do |i|
        2.times { Agent::Errors.record("src#{i}", "boom", now: Time.now) }
      end
      sources = Agent::Errors.list.map { |e| e["source"] }
      assert_equal Agent::Errors::MAX_SOURCES, sources.uniq.length
      assert_equal 0, Agent::Errors.count("src0"), "the least recently failing source goes first"
      assert_equal 2, Agent::Errors.count("src1"), "...and it goes whole, leaving the survivors' counts intact"
    end
  end

  def test_entries_stay_in_the_order_they_were_recorded
    with_state_dir do
      %w[a b a c b].each_with_index { |source, i| Agent::Errors.record(source, "err#{i}", now: Time.now) }
      assert_equal %w[err0 err1 err2 err3 err4], Agent::Errors.list.map { |e| e["message"] }
    end
  end

  # ISS-742's second half. The tick mutates this log from BOTH phases — Phase A
  # under vitals_lock, Phase B under work_lock — and Phase B is designed to
  # overlap the next tick's Phase A, so neither of those locks excludes the
  # other. Without a lock of its own, a `clear` that read the list before a
  # concurrent `record` wrote it put the file back without that failure in it.
  #
  # Asserted from INSIDE the critical section rather than by racing two threads:
  # flock arbitrates between open file descriptions, so a second descriptor in
  # this same process is a real contender and the answer is deterministic.
  def test_record_holds_the_error_log_lock_across_its_read_modify_write
    assert_locked_during_write { Agent::Errors.record("docker_prune", "boom", now: Time.now) }
  end

  def test_clear_holds_the_error_log_lock_across_its_read_modify_write
    assert_locked_during_write { Agent::Errors.clear("docker_prune") }
  end

  def assert_locked_during_write
    with_state_dir do
      held = nil
      original = Agent::Errors.method(:write)
      # `self` inside the stub is Agent::Errors, so the probe is bound here.
      probe = method(:lock_free?)
      stub_singleton(Agent::Errors, :write, lambda { |entries|
        held = !probe.call
        original.call(entries)
      }) { yield }
      assert held, "the log's own lock must be held across the read-modify-write, not just around the write"
    end
  end

  # Whether the error log's lock is free right now, from a second descriptor.
  def lock_free?
    Agent::Paths.mkdir_p(File.dirname(Agent::Paths.errors_lock), mode: 0700)
    file = File.open(Agent::Paths.errors_lock, File::CREAT | File::RDWR, 0600)
    file.flock(File::LOCK_EX | File::LOCK_NB) != false
  ensure
    file&.close
  end

  def test_each_entry_carries_source_message_and_iso8601_created_at
    with_state_dir do
      Agent::Errors.record("checkout_pull", "boom", now: Time.utc(2026, 8, 5, 10, 30))
      entry = Agent::Errors.list.first
      assert_equal "checkout_pull", entry["source"]
      assert_equal "boom", entry["message"]
      assert_equal "2026-08-05T10:30:00Z", entry["created_at"]
    end
  end
end
