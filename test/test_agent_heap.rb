#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/heap'
require 'agent/paths'
require 'agent/tick'
require 'agent/verify'

# The per-machine sbt heap (ISS-753).
#
# Every failure this guards is silent, and each is silent in its own way:
#
#   a heap sized for another box   the fleet ran one constant, `-Xmx12G`, on a
#                                  24G machine with three slots and on a 64G
#                                  machine with one. Nothing errors — the small
#                                  box swaps and the big box leaves half its
#                                  memory unused, and both look like slow builds.
#   a floor nobody measured        drop below what platform needs to COMPILE and
#                                  every Scala build in the fleet dies of an OOM
#                                  that reads like a broken branch.
#   an unknown concurrency guessed the server owns max_concurrency, override
#                                  included. A local re-derivation would disagree
#                                  with it the day either rule changes, and would
#                                  disagree QUIETLY.
#   a value nothing consumes       the derivation is only worth having if it
#                                  reaches sbt. The two spawners that do not go
#                                  through a login shell are the ones that can
#                                  carry it, so both must.
class TestAgentHeap < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |root|
      previous = ENV["DEV_AGENT_STATE_DIR"]
      begin
        ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
        FileUtils.mkdir_p(ENV["DEV_AGENT_STATE_DIR"])
        yield root
      ensure
        ENV["DEV_AGENT_STATE_DIR"] = previous
      end
    end
  end

  def gb(count) = count * (1024**3)

  # ---- the derivation ----

  # The two machines in the fleet on the day this was written, and the whole
  # reason a constant could not serve both.
  def test_derives_the_two_fleet_machines_in_opposite_directions
    # 24G, three slots: 8G per slot, 60% of it. The old constant asked this box
    # for 36G of ceiling.
    assert_equal 4, Agent::Heap.gigabytes(memory_bytes: gb(24), concurrency: 3)
    # 64G, one slot: 38G by the formula, held at the runaway ceiling. The old
    # constant left this box at 12G.
    assert_equal Agent::Heap::MAX_GB, Agent::Heap.gigabytes(memory_bytes: gb(64), concurrency: 1)
  end

  def test_never_below_the_measured_floor
    # A 4G machine has no business running platform, but the answer still has to
    # be one sbt can compile with rather than an arithmetic artefact.
    assert_equal Agent::Heap::MIN_GB, Agent::Heap.gigabytes(memory_bytes: gb(4), concurrency: 3)
    assert_equal Agent::Heap::MIN_GB, Agent::Heap.gigabytes(memory_bytes: 0, concurrency: 1)
    assert_equal Agent::Heap::MIN_GB, Agent::Heap.gigabytes(memory_bytes: nil, concurrency: 1)
  end

  # A zero or negative slot count is a division by zero, and the tick reads this
  # number off a server response.
  def test_a_nonsense_concurrency_does_not_divide_by_zero
    assert_equal Agent::Heap::MAX_GB, Agent::Heap.gigabytes(memory_bytes: gb(64), concurrency: 0)
    assert_equal Agent::Heap::MAX_GB, Agent::Heap.gigabytes(memory_bytes: gb(64), concurrency: -3)
  end

  def test_more_slots_never_means_more_heap
    sizes = (1..8).map { |n| Agent::Heap.gigabytes(memory_bytes: gb(64), concurrency: n) }
    assert_equal sizes.sort.reverse, sizes
  end

  # -Xss4M is not decoration: supplying -Xmx suppresses sbt's own memory
  # defaults, and that is one of them.
  def test_opts_carry_the_stack_sbt_stops_supplying
    opts = Agent::Heap.opts(memory_bytes: gb(24), concurrency: 3)
    assert_equal "-Xmx4G -Xss4M", opts
  end

  # -Xms COMMITS the heap at JVM start. Emitting one would reserve the whole
  # ceiling on a machine sized to share it — the exact defect found in the
  # runner's own login profile.
  def test_opts_never_commit_the_heap
    refute_match(/-Xms/, Agent::Heap.opts(memory_bytes: gb(64), concurrency: 1))
  end

  # ---- the cached concurrency ----

  def test_remembers_what_the_registry_said
    with_state_dir do
      assert_nil Agent::Heap.concurrency
      Agent::Heap.remember({ "max_concurrency" => 3 })
      assert_equal 3, Agent::Heap.concurrency
      Agent::Heap.remember({ "max_concurrency" => 1 })
      assert_equal 1, Agent::Heap.concurrency, "an operator's override must reach the heap"
    end
  end

  # The claim path calls this. A fleet read that came back thin is not worth an
  # exception there, and a nil must not erase a value that was right.
  def test_remembering_a_junk_row_keeps_the_last_known_value
    with_state_dir do
      Agent::Heap.remember({ "max_concurrency" => 3 })
      [nil, {}, { "max_concurrency" => nil }, { "max_concurrency" => 0 }, "not a hash"].each do |row|
        assert_nil Agent::Heap.remember(row)
        assert_equal 3, Agent::Heap.concurrency
      end
    end
  end

  # Unknown resolves to the floor rather than to a local copy of the server's
  # rule. The floor is the conservative end: it can only under-spend a slot, and
  # the next tick fills the cache in.
  def test_an_unknown_concurrency_falls_back_to_the_floor_not_to_a_guess
    with_state_dir do
      assert_equal "-Xmx#{Agent::Heap::MIN_GB}G -Xss4M", Agent::Heap.sbt_opts
    end
  end

  # ---- what actually consumes it ----
  #
  # Both spawners bypass the login shell, which is what makes them the two places
  # the derived value survives to sbt.

  def test_a_session_is_spawned_with_the_derived_heap
    with_state_dir do
      Agent::Heap.remember({ "max_concurrency" => 3 })
      tick = Agent::Tick.new(use_localhost: true, claude_argv: ["claude"], dry_run: true)
      env = tick.send(:child_env, "iss-753", 753)
      assert_equal Agent::Heap.sbt_opts, env["SBT_OPTS"]
    end
  end

  def test_a_ci_build_is_spawned_with_the_derived_heap
    with_state_dir do
      Agent::Heap.remember({ "max_concurrency" => 3 })
      env = Agent::Verify.send(:build_env, repo: "mbryzek/platform", sha: "abc123",
                                           pr: 1, event: "pull_request", clean: false)
      assert_equal Agent::Heap.sbt_opts, env["SBT_OPTS"]
    end
  end

  # The reference build script must not carry a number of its own: one that
  # disagreed with the environment would be silently ignored anyway (sbt's
  # launcher puts SBT_OPTS after `-J` args), which is the worst of both.
  def test_the_scala_ci_template_names_no_heap
    script = File.read(File.expand_path("../templates/ci/build-scala.sh", __dir__))
    body = script.lines.reject { |line| line.start_with?("#") }.join
    refute_match(/-J-Xmx|-Xmx\d/, body)
  end

  # ---- what a repo declares, and who can serve it (ISS-1123) ----
  #
  # The other direction of the same number. The derivation above stops a slot
  # over-requesting memory; these stop a JOB landing in a slot too small for it,
  # which until ISS-1123 nothing did — a platform build needing 12G was claimable
  # on the 24G/3-slot runner that gives 4G, and OOMed there as a red the merge
  # lane cannot tell from a failing suite.

  def test_a_declared_heap_is_read_out_of_the_ci_needs_list
    assert_equal 12, Agent::Heap.requirement(%w[docker registry database heap:12G])
    assert_equal 8, Agent::Heap.requirement(["heap:8"])
    assert_equal 8, Agent::Heap.requirement(["HEAP: 8 gb"])
    assert_nil Agent::Heap.requirement(%w[docker database])
    assert_nil Agent::Heap.requirement([])
    assert_nil Agent::Heap.requirement(nil)
  end

  # THE TYPO THAT WOULD OTHERWISE MEAN "NO MINIMUM". Every other name in
  # `ci-needs` is ignored when it is not recognised, so that a script naming a
  # probe a newer `dev` will have still runs. Under that rule a misspelt heap
  # token reads as no declaration, the job lands on the small box and OOMs —
  # reintroducing, silently, the exact failure the declaration exists to prevent.
  # So a token that NAMES heap and does not parse is an error at both readers.
  def test_a_malformed_heap_token_is_an_error_and_never_silence
    ["heap=12G", "heap:twelve", "heap", "heap:12G:extra", "heap:-4G"].each do |token|
      assert_equal :malformed, Agent::Heap.requirement([token]),
                   "#{token.inspect} must not read as `no minimum` — that is the OOM this prevents"
    end
    assert_nil Agent::Heap.requirement(["heapdump"]),
               "a word boundary is what keeps a future unrelated name from being caught by this"
  end

  # ONE NUMBER, READ BOTH WAYS. `sbt_opts` is what the build is GIVEN and
  # `gigabytes_here` is what a job is MATCHED against; a second derivation would
  # be a matcher that agrees with the environment on the day it is written.
  def test_the_matched_heap_is_the_heap_the_build_is_actually_given
    with_state_dir do
      Agent::Heap.remember({ "max_concurrency" => 3 })
      bytes = gb(24)
      stub_singleton(Agent::Heap, :memory_bytes, -> { bytes }) do
        assert_equal 4, Agent::Heap.gigabytes_here
        assert_equal "-Xmx4G -Xss4M", Agent::Heap.sbt_opts
      end
    end
  end

  # A registry row's machine, by the same formula. Both facts are reported at
  # registration and both come back on GET /agent/runners.
  def test_another_runners_heap_is_derived_from_its_registry_row
    assert_equal 24, Agent::Heap.runner_gigabytes("memory_bytes" => gb(64), "max_concurrency" => 1)
    assert_equal 4, Agent::Heap.runner_gigabytes("memory_bytes" => gb(24), "max_concurrency" => 3)
  end

  # UNKNOWN IS NOT A CAPABILITY. `gigabytes` answers the floor for unknown memory,
  # which is the right conservative answer for THIS box (it under-spends) and the
  # wrong one for another (it would claim 4G we have not established).
  def test_a_row_that_does_not_say_claims_nothing
    assert_nil Agent::Heap.runner_gigabytes("max_concurrency" => 3)
    assert_nil Agent::Heap.runner_gigabytes("memory_bytes" => gb(64))
    assert_nil Agent::Heap.runner_gigabytes("memory_bytes" => 0, "max_concurrency" => 1)
    assert_nil Agent::Heap.runner_gigabytes(nil)
  end

  def test_the_fleet_figure_is_the_biggest_runner_in_it
    laptop = { "memory_bytes" => gb(64), "max_concurrency" => 1 }
    mini = { "memory_bytes" => gb(24), "max_concurrency" => 3 }
    assert_equal 24, Agent::Heap.fleet_gigabytes([mini, laptop])
    assert_equal 4, Agent::Heap.fleet_gigabytes([mini])
  end

  # HARDWARE, NOT AVAILABILITY. The caller uses this to decide whether a job is
  # unsatisfiable BY CONSTRUCTION and files an issue when it is, so a big box that
  # is merely asleep or paused for an hour must not become an alarm. Only a
  # retired machine is gone for good.
  def test_a_paused_or_offline_runner_still_counts_and_a_retired_one_does_not
    laptop = { "memory_bytes" => gb(64), "max_concurrency" => 1 }
    mini = { "memory_bytes" => gb(24), "max_concurrency" => 3 }
    assert_equal 24, Agent::Heap.fleet_gigabytes([mini, laptop.merge("paused" => true)])
    assert_equal 24, Agent::Heap.fleet_gigabytes([mini, laptop.merge("is_stale" => true)])
    assert_equal 4, Agent::Heap.fleet_gigabytes([mini, laptop.merge("retired_at" => "2026-01-01T00:00:00Z")])
  end

  # nil, never zero: a fleet nothing is known about must downgrade every
  # unsatisfiable verdict to a deferral rather than declaring every job
  # unbuildable. "Nobody can build this" is worth saying only about a fleet
  # actually read.
  def test_an_unreadable_fleet_is_unknown_rather_than_empty
    assert_nil Agent::Heap.fleet_gigabytes(nil)
    assert_nil Agent::Heap.fleet_gigabytes([])
    assert_nil Agent::Heap.fleet_gigabytes([{ "hostname" => "no hardware reported" }])
  end

  # ---- the profile that beats all of the above ----

  def test_profile_override_reports_only_a_pinned_heap
    assert_equal " -Xms40G -Xmx40G -Xss2M", Agent::Heap.profile_override(" -Xms40G -Xmx40G -Xss2M")
    assert_equal "-Xmx12G", Agent::Heap.profile_override("-Xmx12G")
    assert_nil Agent::Heap.profile_override(nil)
    assert_nil Agent::Heap.profile_override("")
    assert_nil Agent::Heap.profile_override("-Dsbt.color=always -Xss4M")
  end
end
