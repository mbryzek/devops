#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/ops'

# The ops close-out contract (ISS-815): the record `dev agent run-op` writes when
# a session RUNS something, and the properties Agent::Outcome then classifies on.
#
# Two of these matter more than the rest and are worth naming up front, because
# both are ways this contract could silently report success where there was none:
# an operation that FAILED must never be filed as a success (`succeeded?`), and a
# PREVIOUS attempt's record must never close out an attempt that did nothing
# (`records(since:)`).
class TestDevAgentOps < Minitest::Test
  ISSUE = 815

  def with_log_root
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_LOG_ROOT"]
      ENV["DEV_AGENT_LOG_ROOT"] = File.join(root, "logs")
      begin
        yield root
      ensure
        ENV["DEV_AGENT_LOG_ROOT"] = original
      end
    end
  end

  def record(**overrides)
    Agent::Ops::Record.new(**{ operation: "features-reconcile", argv: %w[dev features reconcile --apply],
                               status: 0, timed_out: false, summary: "2 processed, 1 purged, 5 outstanding.",
                               effects: { "processed" => 2 }, started_at: "2026-08-07T15:00:00Z",
                               finished_at: "2026-08-07T15:00:12Z", output_tail: "" }.merge(overrides))
  end

  # ---- the marker: an operation declaring what it did ----

  def emitting
    original = ENV[Agent::Ops::LISTENER_ENV]
    ENV[Agent::Ops::LISTENER_ENV] = "1"
    yield
  ensure
    ENV[Agent::Ops::LISTENER_ENV] = original
  end

  def test_emit_and_extract_round_trip_the_summary_and_the_effects
    io = StringIO.new
    emitting do
      Agent::Ops.emit(summary: "2 processed, 1 purged.", effects: { "processed" => 2, "purged" => 1 }, io: io)
    end
    report, visible = Agent::Ops.extract("before\n#{io.string}after\n")

    assert_equal "2 processed, 1 purged.", report["summary"]
    assert_equal({ "processed" => 2, "purged" => 1 }, report["effects"])
    # The marker is machinery, not output: it never reaches the human reading the
    # release log or the session transcript.
    assert_equal "before\nafter\n", visible
  end

  # An operation that emitted nothing still gets a record — it just cannot say
  # more than its exit status. `api publish` is one until somebody instruments it.
  def test_output_with_no_marker_reports_nothing_and_is_passed_through_whole
    report, visible = Agent::Ops.extract("published 104 applications\n")
    assert_nil report
    assert_equal "published 104 applications\n", visible
  end

  # A truncated marker costs the SUMMARY, never the record: this parses the output
  # of a command that may have been killed halfway through writing that line.
  def test_an_unparseable_marker_is_dropped_rather_than_raised_on
    report, visible = Agent::Ops.extract("#{Agent::Ops::MARKER} {\"summary\": \n")
    assert_nil report
    assert_equal "", visible
  end

  def test_the_last_marker_wins
    lines = ["#{Agent::Ops::MARKER} {\"summary\":\"first\"}", "#{Agent::Ops::MARKER} {\"summary\":\"second\"}"]
    report, = Agent::Ops.extract("#{lines.join("\n")}\n")
    assert_equal "second", report["summary"]
  end

  # The same reconcilers run inline from `dev deploy`, where stdout is the
  # release log Mike is watching. The marker is a protocol between `run-op` and
  # the operation it runs, so it is spoken only when `run-op` is on the other end
  # — never on a laptop, and never in a release log.
  def test_nothing_is_emitted_when_no_ops_run_is_listening
    io = StringIO.new
    refute Agent::Ops.emit(summary: "2 processed.", io: io)
    assert_equal "", io.string
  end

  # ---- succeeded?: the predicate the failure arm turns on ----

  def test_only_a_zero_exit_that_was_not_killed_counts_as_success
    assert Agent::Ops.succeeded?(record(status: 0))
    refute Agent::Ops.succeeded?(record(status: 1))
    # No exit status at all, because Agent::Shell killed it on its deadline.
    # There is no reason to believe it finished what it started.
    refute Agent::Ops.succeeded?(record(status: nil, timed_out: true))
    assert_equal ["features-reconcile"], Agent::Ops.failed([record(status: 0), record(status: 2)])
      .map(&:operation).uniq
  end

  # ---- describe: what goes on the issue timeline ----

  # The payload of the whole contract. "reconcile applied 2 transitions" versus
  # "reconcile applied 0" is the value of having run it, and an ops arm that
  # recorded neither would have rebuilt ISS-809's failure mode in a new place.
  def test_describe_carries_what_each_operation_did
    described = Agent::Ops.describe([record, record(operation: "issues-reconcile", summary: "3 deployed.")])
    assert_equal "features-reconcile — 2 processed, 1 purged, 5 outstanding.; issues-reconcile — 3 deployed.",
                 described
  end

  # An uninstrumented operation says so, rather than rendering as an empty clause
  # that reads like a summary somebody forgot to fill in.
  def test_an_operation_that_reported_nothing_says_so
    assert_equal "api-publish — ran (reported no effects)",
                 Agent::Ops.describe([record(operation: "api-publish", summary: nil)])
    assert_equal "features-reconcile — exited 3", Agent::Ops.describe([record(status: 3)])
    assert_equal "features-reconcile — timed out", Agent::Ops.describe([record(status: nil, timed_out: true)])
  end

  # ---- the record on disk ----

  def test_a_record_round_trips_through_the_log_tree
    with_log_root do
      Agent::Ops.write(ISSUE, record)
      read = Agent::Ops.records(ISSUE)
      assert_equal 1, read.length
      assert_equal "features-reconcile", read.first.operation
      assert_equal "2 processed, 1 purged, 5 outstanding.", read.first.summary
      assert_equal %w[dev features reconcile --apply], read.first.argv
      assert_equal 0, read.first.status
    end
  end

  # Sequenced, so a run's operations read back in the order they happened — which
  # is the order `describe` then puts them on the timeline.
  def test_records_read_back_in_the_order_they_ran
    with_log_root do
      %w[api-publish changelog features-reconcile].each { |op| Agent::Ops.write(ISSUE, record(operation: op)) }
      assert_equal %w[api-publish changelog features-reconcile], Agent::Ops.records(ISSUE).map(&:operation)
    end
  end

  # THE ONE THAT MATTERS. The issue directory outlives an attempt (claude.log is
  # appended across them on purpose), so attempt 1 running the operation and then
  # crashing leaves a successful record behind. Attempt 2, which did nothing at
  # all, must not read it and close the issue out — the same "an earlier run's
  # evidence proves this run" mistake ISS-741 fixed on the reap's own verdict.
  def test_a_previous_attempts_record_is_not_this_attempts_result
    with_log_root do
      Agent::Ops.write(ISSUE, record(started_at: "2026-08-07T09:00:00Z"))
      Agent::Ops.write(ISSUE, record(operation: "issues-reconcile", started_at: "2026-08-07T15:00:00Z"))

      this_attempt = Agent::Ops.records(ISSUE, since: Time.parse("2026-08-07T14:00:00Z"))
      assert_equal %w[issues-reconcile], this_attempt.map(&:operation)
      assert_equal 2, Agent::Ops.records(ISSUE).length, "both are still on disk for the post-mortem"
    end
  end

  # A record that cannot be attributed to an attempt is EXCLUDED, not kept.
  # Excluding degrades to the behaviour that existed before this contract;
  # including would let a truncated or hand-edited file manufacture a success.
  def test_a_record_with_an_unreadable_timestamp_is_not_attributed_to_this_attempt
    with_log_root do
      Agent::Ops.write(ISSUE, record(started_at: "not a time"))
      assert_empty Agent::Ops.records(ISSUE, since: Time.parse("2026-08-07T14:00:00Z"))
    end
  end

  def test_a_corrupt_record_file_is_skipped_rather_than_raised_on
    with_log_root do
      dir = Agent::Paths.mkdir_p(Agent::Paths.ops_dir(ISSUE))
      File.write(File.join(dir, "001-truncated.json"), "{\"operation\":")
      Agent::Ops.write(ISSUE, record)
      assert_equal %w[features-reconcile], Agent::Ops.records(ISSUE).map(&:operation)
    end
  end

  # Operation names become filenames. Refused rather than sanitized, for the same
  # reason Agent::Workspace refuses a slug it could not itself have minted: this
  # runs unattended and the directory it writes into is one `..` from somewhere
  # else.
  def test_an_operation_name_this_module_could_not_have_minted_is_refused
    ["../../etc/passwd", "Features Reconcile", "", "a" * 49, "-leading-dash"].each do |name|
      refute Agent::Ops.valid_name?(name), "#{name.inspect} must not be accepted as an operation name"
    end
    %w[features-reconcile api-publish dev_changelog v2.0].each do |name|
      assert Agent::Ops.valid_name?(name), "#{name.inspect} is an ordinary operation name"
    end
  end

  def test_run_refuses_an_invalid_operation_name_before_executing_anything
    with_log_root do
      assert_raises(ArgumentError) do
        Agent::Ops.run(number: ISSUE, operation: "../escape", argv: ["true"])
      end
    end
  end

  # ---- end to end, against a real subprocess ----

  # The whole contract in one pass: the operation's exit status and the operation's
  # own marker line become the record, and the marker never reaches the reader.
  def test_run_records_the_operations_own_status_and_its_own_report
    with_log_root do
      script = "echo working; echo '#{Agent::Ops::MARKER} {\"summary\":\"2 applied.\",\"effects\":{\"applied\":2}}'"
      rec, visible = Agent::Ops.run(number: ISSUE, operation: "features-reconcile",
                                    argv: ["/bin/sh", "-c", script], timeout: 30)

      assert_equal 0, rec.status
      assert_equal "2 applied.", rec.summary
      assert_equal({ "applied" => 2 }, rec.effects)
      assert_equal "working\n", visible
      assert_equal "working\n", rec.output_tail
      assert Agent::Ops.succeeded?(rec)
      assert_equal [rec.operation], Agent::Ops.records(ISSUE).map(&:operation)
    end
  end

  # A failing operation is filed as a failure with its output kept — which is the
  # input to Agent::Outcome's failure arm, and the diagnosis a human reads after.
  def test_run_files_a_failing_operation_as_a_failure
    with_log_root do
      rec, = Agent::Ops.run(number: ISSUE, operation: "features-reconcile",
                            argv: ["/bin/sh", "-c", "echo could not reach the platform >&2; exit 4"], timeout: 30)
      refute Agent::Ops.succeeded?(rec)
      assert_equal 4, rec.status
      assert_match(/could not reach the platform/, rec.output_tail)
      assert_equal [rec], Agent::Ops.failed([rec])
    end
  end

  def test_run_files_a_hung_operation_as_a_timeout_rather_than_an_exit_status
    with_log_root do
      rec, = Agent::Ops.run(number: ISSUE, operation: "hangs", argv: ["/bin/sh", "-c", "sleep 30"], timeout: 1)
      assert rec.timed_out
      assert_nil rec.status, "a deadline is not an answer the command gave"
      refute Agent::Ops.succeeded?(rec)
    end
  end

  # Two records must never collide onto one filename. The overwrite would lose a
  # record in the one direction that matters — the one it destroys may be the
  # FAILED one, turning a run that broke into a run that reads as clean.
  def test_two_records_for_the_same_operation_never_overwrite_each_other
    with_log_root do
      Agent::Ops.write(ISSUE, record(status: 1))
      Agent::Ops.write(ISSUE, record(status: 0))
      assert_equal [1, 0], Agent::Ops.records(ISSUE).map(&:status)
      assert_equal 1, Agent::Ops.failed(Agent::Ops.records(ISSUE)).length
    end
  end

  # An operation is free to print bytes that are not valid UTF-8, and
  # `JSON.generate` raises on them — a raise that would come out of `write` and
  # lose the record of a run that really happened.
  def test_output_that_is_not_valid_utf8_does_not_cost_the_record
    with_log_root do
      rec, = Agent::Ops.run(number: ISSUE, operation: "noisy",
                            argv: ["/bin/sh", "-c", "printf 'caf\\xe9\\n'"], timeout: 30)
      assert_equal 0, rec.status
      assert_equal [rec.operation], Agent::Ops.records(ISSUE).map(&:operation)
    end
  end

  # The record is a post-mortem aid, not a log — claude.log already has every
  # byte — so one chatty operation cannot fill the issue tree.
  def test_a_chatty_operations_output_is_bounded_on_the_record
    tail = Agent::Ops.tail("x" * (Agent::Ops::OUTPUT_TAIL_BYTES + 5_000))
    assert_operator tail.bytesize, :<=, Agent::Ops::OUTPUT_TAIL_BYTES + 10
    assert tail.start_with?("...\n"), "a truncated tail says it was truncated"
  end
end
