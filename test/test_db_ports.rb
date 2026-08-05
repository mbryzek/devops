#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../lib/common'
require_relative 'test_helper'

# Port allocation is the part of the per-tag container split that can silently
# hurt: hand two sessions the same port and one of them ends up talking to the
# other's database. The arithmetic is therefore pure and tested here — wrap,
# skip, and exhaustion — with an injected "is it bound" predicate and a temp
# history file, so no test touches the real ~/code/ai/.claude-db-ports.json or
# needs a Docker daemon.
class TestDbPorts < Minitest::Test
  include DevTestSupport

  MIN = DbPorts::RANGE_MIN
  MAX = DbPorts::RANGE_MAX

  NOTHING_BOUND = ->(_port) { false }

  def with_history_file(contents = nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".claude-db-ports.json")
      File.write(path, JSON.pretty_generate(contents)) if contents
      yield path
    end
  end

  def alloc(port, container: "platformdb-claude-0.1.#{port}")
    {
      "port" => port,
      "schema_tag" => "0.1.#{port}",
      "container" => container,
      "session_id" => "sess-#{port}",
      "allocated_at" => "2026-07-29T00:00:00Z"
    }
  end

  # ── next_free_port: the pure arithmetic ───────────────────────────────────

  def test_empty_history_starts_at_the_bottom_of_the_range
    assert_equal MIN, DbPorts.next_free_port(
      :last_issued => nil, :taken => Set.new, :bound => NOTHING_BOUND
    )
  end

  def test_allocation_is_sequential
    assert_equal MIN + 1, DbPorts.next_free_port(
      :last_issued => MIN, :taken => Set.new, :bound => NOTHING_BOUND
    )
    assert_equal MIN + 2, DbPorts.next_free_port(
      :last_issued => MIN + 1, :taken => Set.new, :bound => NOTHING_BOUND
    )
  end

  # The whole reason last_issued is persisted: "highest recorded + 1" is 10000
  # here, which is out of range.
  def test_wraps_from_the_top_of_the_range_back_to_the_bottom
    assert_equal MIN, DbPorts.next_free_port(
      :last_issued => MAX, :taken => Set.new, :bound => NOTHING_BOUND
    )
  end

  def test_after_wrapping_it_keeps_going_forward_from_the_bottom
    assert_equal MIN + 1, DbPorts.next_free_port(
      :last_issued => MIN, :taken => Set.new, :bound => NOTHING_BOUND
    )
  end

  def test_skips_a_port_reserved_in_history
    assert_equal MIN + 1, DbPorts.next_free_port(
      :last_issued => nil, :taken => Set[MIN], :bound => NOTHING_BOUND
    )
  end

  def test_skips_a_port_bound_on_the_host
    bound = ->(port) { port == MIN || port == MIN + 1 }
    assert_equal MIN + 2, DbPorts.next_free_port(
      :last_issued => nil, :taken => Set.new, :bound => bound
    )
  end

  # A stale history entry must never be enough, on its own, to hand out a port
  # something is actually listening on.
  def test_bind_check_overrides_a_history_that_thinks_the_port_is_free
    bound = ->(port) { port == MIN }
    assert_equal MIN + 1, DbPorts.next_free_port(
      :last_issued => nil, :taken => Set.new, :bound => bound
    )
  end

  def test_wraps_past_the_top_and_skips_taken_ports_below
    taken = Set[MIN, MIN + 1]
    assert_equal MIN + 2, DbPorts.next_free_port(
      :last_issued => MAX, :taken => taken, :bound => NOTHING_BOUND
    )
  end

  def test_exhaustion_returns_nil_rather_than_looping_forever
    everything = (MIN..MAX).to_set
    assert_nil DbPorts.next_free_port(
      :last_issued => nil, :taken => everything, :bound => NOTHING_BOUND
    )
  end

  def test_exhaustion_via_bound_ports_also_terminates
    assert_nil DbPorts.next_free_port(
      :last_issued => MIN + 10, :taken => Set.new, :bound => ->(_p) { true }
    )
  end

  def test_out_of_range_last_issued_restarts_at_the_bottom
    assert_equal MIN, DbPorts.next_free_port(
      :last_issued => 5433, :taken => Set.new, :bound => NOTHING_BOUND
    )
  end

  # ── reserved_ports: which history entries still count ─────────────────────

  def test_reserved_ports_counts_entries_whose_container_still_exists
    history = { "last_issued" => 5501, "allocations" => [alloc(5500), alloc(5501)] }
    reserved = DbPorts.reserved_ports(history, :container_exists => ->(_n) { true })
    assert_equal Set[5500, 5501], reserved
  end

  # A container that is gone releases its port — otherwise the range leaks and
  # eventually exhausts on nothing.
  def test_reserved_ports_drops_stale_entries
    history = { "last_issued" => 5501, "allocations" => [alloc(5500), alloc(5501)] }
    exists = ->(name) { name == "platformdb-claude-0.1.5500" }
    assert_equal Set[5500], DbPorts.reserved_ports(history, :container_exists => exists)
  end

  def test_reserved_ports_ignores_out_of_range_entries
    history = { "last_issued" => nil, "allocations" => [alloc(5433)] }
    assert_empty DbPorts.reserved_ports(history, :container_exists => ->(_n) { true })
  end

  # ── history file ──────────────────────────────────────────────────────────

  def test_missing_history_file_reads_as_empty
    with_history_file do |path|
      refute File.exist?(path)
      assert_equal DbPorts.empty_history, DbPorts.load_history(path)
    end
  end

  def test_record_appends_and_sets_last_issued
    with_history_file do |path|
      DbPorts.record(
        :port => 5500, :schema_tag => "0.5.22",
        :container => "platformdb-claude-0.5.22", :session_id => "db-per-tag",
        :path => path, :now => Time.utc(2026, 7, 29, 12, 0, 0)
      )
      history = JSON.parse(File.read(path))
      assert_equal 5500, history["last_issued"]
      assert_equal 1, history["allocations"].length
      entry = history["allocations"].first
      assert_equal 5500, entry["port"]
      assert_equal "0.5.22", entry["schema_tag"]
      assert_equal "platformdb-claude-0.5.22", entry["container"]
      assert_equal "db-per-tag", entry["session_id"]
      assert_equal "2026-07-29T12:00:00Z", entry["allocated_at"]
    end
  end

  def test_record_keeps_prior_allocations
    with_history_file do |path|
      DbPorts.record(:port => 5500, :schema_tag => "a", :container => "c-a",
                     :session_id => "s", :path => path)
      DbPorts.record(:port => 5501, :schema_tag => "b", :container => "c-b",
                     :session_id => "s", :path => path)
      history = DbPorts.load_history(path)
      assert_equal [5500, 5501], history["allocations"].map { |a| a["port"] }
      assert_equal 5501, history["last_issued"]
    end
  end

  def test_release_container_frees_only_that_containers_ports
    with_history_file do |path|
      DbPorts.record(:port => 5500, :schema_tag => "a", :container => "c-a",
                     :session_id => "s", :path => path)
      DbPorts.record(:port => 5501, :schema_tag => "b", :container => "c-b",
                     :session_id => "s", :path => path)
      assert_equal 1, DbPorts.release_container("c-a", :path => path)
      history = DbPorts.load_history(path)
      assert_equal ["c-b"], history["allocations"].map { |a| a["container"] }
      # last_issued survives so the sequence keeps moving forward instead of
      # immediately recycling the port just released.
      assert_equal 5501, history["last_issued"]
    end
  end

  # A corrupt file must not wedge every session — the liveness checks are what
  # actually keep an occupied port from being handed out.
  def test_corrupt_history_reads_as_empty_instead_of_raising
    with_history_file do |path|
      File.write(path, "{not json")
      history = nil
      _out, _err = capture_io { history = DbPorts.load_history(path) }
      assert_equal DbPorts.empty_history, history
    end
  end

  # ── allocate! : the file + arithmetic together ────────────────────────────

  def test_allocate_persists_last_issued_so_concurrent_callers_differ
    with_history_file do |path|
      first = DbPorts.allocate!(:path => path, :container_exists => ->(_n) { true },
                                :bound => NOTHING_BOUND)
      second = DbPorts.allocate!(:path => path, :container_exists => ->(_n) { true },
                                 :bound => NOTHING_BOUND)
      assert_equal MIN, first
      assert_equal MIN + 1, second
      assert_equal MIN + 1, DbPorts.load_history(path)["last_issued"]
    end
  end

  # The test above proves SEQUENTIAL callers differ, which is what its name has
  # always claimed but not what the file is for: the history exists so that
  # parallel sessions -- separate processes that cannot see each other's shells
  # -- never get the same port. That needs real concurrency to test, so this
  # forks.
  #
  # Without the lock, `allocate!` loads, computes and saves with nothing holding
  # the file in between, and N processes starting together all read the same
  # `last_issued` and return the same port. (The `bound` probe does not save it:
  # TCPServer is opened and closed to test a port, not held.) Hand two sessions
  # the same port and one ends up talking to the other's database, which is the
  # whole hazard this file exists to prevent.
  def test_parallel_processes_are_never_handed_the_same_port
    with_history_file do |path|
      readers, writers = 8.times.map { IO.pipe }.transpose
      pids = 8.times.map do |i|
        fork do
          readers.each(&:close)
          # A barrier: without it the children serialise by luck of scheduling
          # and the race never opens, so the test would pass either way.
          sleep 0.05
          port = DbPorts.allocate!(:path => path, :container_exists => ->(_n) { true },
                                   :bound => NOTHING_BOUND)
          writers[i].write(port.to_s)
          writers[i].close
          exit!(0)
        end
      end
      writers.each(&:close)
      ports = readers.map { |r| v = r.read; r.close; v.to_i }
      pids.each { |pid| Process.wait(pid) }

      assert_equal ports.length, ports.uniq.length, "two processes were handed the same port: #{ports.sort}"
      assert_equal ports.sort, (MIN...MIN + 8).to_a, "the allocations must be a contiguous run"
    end
  end

  def test_allocate_skips_a_port_held_by_a_live_container
    history = {
      "last_issued" => nil,
      "allocations" => [alloc(MIN, :container => "platformdb-claude-live")]
    }
    with_history_file(history) do |path|
      port = DbPorts.allocate!(
        :path => path,
        :container_exists => ->(name) { name == "platformdb-claude-live" },
        :bound => NOTHING_BOUND
      )
      assert_equal MIN + 1, port
    end
  end

  def test_allocate_returns_nil_when_exhausted
    with_history_file do |path|
      assert_nil DbPorts.allocate!(:path => path, :container_exists => ->(_n) { false },
                                   :bound => ->(_p) { true })
    end
  end

  # ── port_bound? : the real socket check ───────────────────────────────────

  def test_port_bound_is_true_for_a_socket_we_hold_open
    server = TCPServer.new(DbPorts::HOST, 0)
    port = server.addr[1]
    assert DbPorts.port_bound?(port)
  ensure
    server&.close
  end

  def test_port_bound_is_false_once_the_socket_is_closed
    server = TCPServer.new(DbPorts::HOST, 0)
    port = server.addr[1]
    server.close
    refute DbPorts.port_bound?(port)
  end
end
