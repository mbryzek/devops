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

  # Cap 10 TOTAL, oldest evicted first — a source that never recovers must not
  # grow this file without bound, and must not starve another source's history
  # either.
  def test_capped_at_ten_total_oldest_evicted_first
    with_state_dir do
      12.times { |i| Agent::Errors.record("checkout_pull", "err#{i}", now: Time.now) }
      entries = Agent::Errors.list
      assert_equal 10, entries.length
      assert_equal %w[err2 err3 err4 err5 err6 err7 err8 err9 err10 err11], entries.map { |e| e["message"] }
    end
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
