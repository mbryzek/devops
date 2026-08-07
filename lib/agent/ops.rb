# The close-out contract for a session whose job is to RUN something.
#
# WHY THIS EXISTS (ISS-815). Agent::Outcome.classify reads artifacts, never
# prose, and until this file every artifact it knew about was a CODE CHANGE: a
# pull request, or a document committed under ~/code/claude/plans/. An issue
# that says "run `dev features reconcile --apply`" produces neither, so a clean
# ops run fell through every arm to `nothing_to_do` — `dismissed` when the issue
# was producer-filed, `needs_input` when it was not. The dismissed arm is the
# dangerous one: a reconcile that moved twelve issues and a reconcile that never
# ran at all classified identically, which is ISS-809's failure mode (silence
# indistinguishable from success) reproduced in the executor.
#
# THE ARTIFACT IS THE OPERATION'S OWN OUTPUT, NOT THE SESSION'S SUMMARY.
#
# The obvious alternative — let the session close its own issue, the way a
# suggestion session does with `dev issues status --status needs_review` — makes
# Claude's judgement the signal, which is the exact rule ISS-364 exists to
# enforce against. So the session does not report anything here. It invokes
# `dev agent run-op`, which EXECUTES the operation and writes the record from
# what the operation itself produced:
#
#   status    the operation's own exit status, from Agent::Shell, never a claim
#   summary   a line the OPERATION printed, through `Ops.emit` below
#   effects   counts the OPERATION computed
#   output    what the operation wrote, so a human can check the other three
#
# Claude never types "applied 2 transitions". It types the command; the command
# says what it did. That is the whole of the trust boundary, and it is worth
# being exact about its limit: a session with a shell can write any file it
# likes, here as anywhere. What this removes is not the theoretical possibility
# of fabrication but the ROUTINE one — a session that summarizes a failed run
# as a success, or an empty run as a busy one, with nobody having lied on
# purpose. The honest path is the only convenient one.
#
# WHAT THE OPERATION DID, not merely that it exited 0. `2 processed, 1 purged`
# versus `0 processed, 0 purged` is the entire value of having run the thing,
# and a contract that records only the exit status would have rebuilt the
# problem it was written to solve. `Ops.emit` is how an operation says it, and
# it is emitted UNCONDITIONALLY — including on the zero state, which is exactly
# where the human-facing tail lines in `bin/dev` deliberately stay silent.
require 'json'
require 'time'
require 'agent/paths'
require 'agent/shell'

module Agent
  module Ops
    # The line an operation prints to declare what it did. A marker rather than
    # a parse of the human-facing output, because the human-facing output is
    # formatting and formatting changes: `features_reconcile_summary` returns
    # nil on the zero state on purpose, and scraping it would have made "nothing
    # moved" and "never ran" the same string again.
    MARKER = "::dev-ops-result::".freeze

    # Set by `run` on the operation's environment, and the whole of what makes
    # the marker a PROTOCOL rather than a leak. The same reconcilers run inline
    # from `dev deploy`, where their stdout is the release log Mike is watching;
    # a machine-readable line spliced into it is noise on every release forever.
    # So an operation speaks the protocol only when something is on the other end
    # of it, and `emit` is a no-op everywhere else — including a laptop.
    #
    # WITHIN an ops run it is unconditional, which is the property that matters:
    # "0 processed" is a result, and an operation that emitted only when it moved
    # something would be an operation whose silence had two meanings.
    LISTENER_ENV = "DEV_AGENT_OPS_RUN".freeze

    # Long enough for `api publish`, which uploads 100+ apibuilder applications
    # and waits on codegen. Bounded anyway: an unbounded ops run inside a session
    # is a session that hits its own 4-hour kill with no record of what it was
    # doing, which is the outcome this file exists to prevent.
    DEFAULT_TIMEOUT_SECONDS = 3600

    # How much of the operation's output is kept on the record. The record is a
    # post-mortem aid, not a log — claude.log already has every byte — so this
    # is bounded to keep one chatty operation from filling the issue tree.
    OUTPUT_TAIL_BYTES = 8_000

    # Operation names become filenames and appear in issue comments, so they are
    # constrained rather than trusted. Same spirit as Agent::Workspace.valid_slug?:
    # a name this module could not itself have minted is refused, not sanitized.
    NAME_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,47}\z/

    # An environment variable name, for `--env KEY=VALUE`. The same shape the
    # shell itself accepts, and refused rather than sanitized for the reason
    # NAME_PATTERN is: a session that meant `--env` and typed something else
    # should be told so before anything runs, not have its intent guessed at.
    ENV_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # `status` is the OPERATION's exit status; nil exactly when it timed out, for
    # the same reason Agent::Shell::Result.status is (a deadline is not an answer
    # the command gave).
    #
    # `env_keys` is the NAMES of the variables `--env` set, never their values.
    # The record is a post-mortem artifact and "this ran with HOMEBREW_NO_AUTOREMOVE
    # set" is the part of it a human needs; the values are session-supplied and may
    # be credentials, which have no business landing in a file on disk that nobody
    # thinks of as holding them.
    Record = Struct.new(:operation, :argv, :status, :timed_out, :summary, :effects,
                        :started_at, :finished_at, :output_tail, :env_keys, keyword_init: true)

    module_function

    # ---- the emit side: an operation declaring what it did ----

    # Printed by the operation, read by `run` below. `summary` is the one line a
    # human reads on the issue timeline; `effects` is the same fact in numbers.
    #
    # Silent unless an ops run is listening (LISTENER_ENV), and never conditional
    # on having DONE anything once one is.
    def emit(summary:, effects: {}, io: $stdout)
      return false unless listening?
      io.puts("#{MARKER} #{JSON.generate({ 'summary' => summary.to_s, 'effects' => effects })}")
      true
    end

    def listening? = !ENV[LISTENER_ENV].to_s.empty?

    # Splits an operation's output into [report, visible output].
    #
    # LAST marker wins, and unparseable ones are dropped rather than raised on:
    # this runs over the output of a command that may have failed halfway, and a
    # truncated JSON line must cost the summary, not the record. `report` is nil
    # when the operation emitted nothing — an uninstrumented operation still gets
    # a record, it just cannot say more than its exit status.
    def extract(output)
      lines = output.to_s.lines
      markers, visible = lines.partition { |line| line.lstrip.start_with?(MARKER) }
      report = markers.reverse.filter_map { |line| parse_marker(line) }.first
      [report, visible.join]
    end

    def parse_marker(line)
      parsed = JSON.parse(line.lstrip.delete_prefix(MARKER).strip)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # ---- the run side: executing one operation and writing its record ----

    # Runs `argv` and writes the record. Returns the Record.
    #
    # Through Agent::Shell like everything else under lib/agent: it is the one
    # place allowed to call Open3 (test_dev_agent_shell.rb asserts it), and the
    # deadline and group-kill it brings are not incidental here — an ops run is
    # unattended by definition.
    #
    # `env` is what `--env KEY=VALUE` collected. It exists because this command
    # takes ARGV and the things it is asked to run are written as SHELL lines —
    # `HOMEBREW_NO_AUTOREMOVE=1 brew uninstall ...` is a toolchain install hint
    # verbatim — and leading assignments are shell syntax with no argv spelling.
    # The obvious translation, prepending `env`, is what ISS-896 is: `env`
    # resolved to `~/code/devops/bin/env`, because `~/code/devops/bin` precedes
    # /usr/bin on this fleet's PATH, and that script died parsing the following
    # words as its own flags. ISS-893 moved that particular file out of the way,
    # but the collision was the symptom: an argv API that cannot express "with
    # this variable set" is incomplete however PATH happens to be arranged, and
    # a session should not have to know what is in devops/bin to run a chore.
    #
    # LISTENER_ENV is merged LAST and so cannot be overridden by `--env`: it is
    # the marker protocol this whole file is built on, not a caller-tunable, and
    # a session that unset it would silently lose every operation's summary.
    def run(number:, operation:, argv:, timeout: DEFAULT_TIMEOUT_SECONDS, now: Time.now, env: {})
      raise ArgumentError, "operation name #{operation.inspect} is not #{NAME_PATTERN.inspect}" unless valid_name?(operation)

      started = now.utc
      result = Agent::Shell.capture(*argv, timeout: timeout, env: env.merge(LISTENER_ENV => "1"))
      report, visible = extract(result.output)
      record = Record.new(
        operation: operation, argv: argv,
        status: result.exitstatus, timed_out: result.timed_out?,
        summary: report && report["summary"], effects: (report && report["effects"]) || {},
        started_at: started.iso8601, finished_at: Time.now.utc.iso8601,
        output_tail: tail(visible), env_keys: env.keys.sort,
      )
      write(number, record)
      [record, visible]
    end

    def valid_name?(operation) = operation.to_s.match?(NAME_PATTERN)

    # Splits one `--env KEY=VALUE` into [key, value], or nil when it is not one.
    #
    # `split("=", 2)` rather than a full split, so a value may itself contain
    # `=` — connection strings and JDBC urls routinely do, and a helper that
    # truncated them at the first one would corrupt exactly the values most
    # worth setting. An empty value is legal (`--env FOO=` sets FOO to ""),
    # which is what the shell does; a missing `=` is not, because `--env FOO`
    # is far more likely a session that meant `FOO=1` than one that meant "".
    def env_assignment(pair)
      key, value = pair.to_s.split("=", 2)
      return nil if value.nil? || !key.to_s.match?(ENV_NAME_PATTERN)
      [key, value]
    end

    # Scrubbed on BOTH paths, not only the truncated one. An operation is free to
    # print bytes that are not valid UTF-8 — a stack trace out of a subprocess, a
    # filename in another encoding — and `JSON.generate` raises on them. That
    # raise would come out of `write`, losing the record of a run that really
    # happened, which is the failure this whole file exists to prevent.
    def tail(output)
      text = output.to_s.scrub
      return text if text.bytesize <= OUTPUT_TAIL_BYTES
      "...\n#{text.byteslice(-OUTPUT_TAIL_BYTES, OUTPUT_TAIL_BYTES).scrub}"
    end

    # One file per operation, sequenced so a run's operations read back in the
    # order they happened. Never overwritten and never deleted between attempts:
    # the log tree is the post-mortem, and `records(since:)` is what keeps a
    # previous attempt's record from being counted as this one's (see below).
    def write(number, record)
      dir = Agent::Paths.mkdir_p(Agent::Paths.ops_dir(number))
      Agent::Paths.write_json(next_record_file(dir, record.operation), to_h(record))
      record
    end

    # The next free sequence, rather than count+1. Two records CAN collide on a
    # count — a resumed attempt writing into a directory a predecessor left, or
    # two operations started in the same moment — and the collision would
    # overwrite, which loses a record in the one direction that matters: the
    # record it destroys may be the failed one, turning a run that broke into a
    # run that reads as clean.
    def next_record_file(dir, operation)
      seq = Dir.glob(File.join(dir, "*.json")).length + 1
      seq += 1 while File.exist?(path = File.join(dir, "#{format('%03d', seq)}-#{operation}.json"))
      path
    end

    def to_h(record) = record.to_h.transform_keys(&:to_s)

    def from_h(hash)
      return nil unless hash.is_a?(Hash)
      return nil if hash["operation"].to_s.empty?
      Record.new(**Record.members.to_h { |field| [field, hash[field.to_s]] })
    end

    # Every operation THIS attempt ran, oldest first.
    #
    # `since` is the job's `started_at`, and it is the whole safety of the arm.
    # The issue directory outlives an attempt — claude.log is appended across
    # them on purpose — so an attempt that ran the operation and then crashed
    # leaves a successful record behind. Without this filter the NEXT attempt,
    # which did nothing at all, would read that record and classify itself
    # `operation_completed`: the same "an earlier run's evidence proves this
    # run" mistake ISS-741 fixed on the reap's own verdict.
    #
    # A record whose timestamp will not parse is EXCLUDED rather than kept. It
    # cannot be attributed to this attempt, and the failure direction matters:
    # excluding degrades to the behaviour that existed before this file, while
    # including would let a corrupt file manufacture a success.
    def records(number, since: nil)
      dir = Agent::Paths.ops_dir(number)
      return [] unless Dir.exist?(dir)
      Dir.glob(File.join(dir, "*.json")).sort
         .filter_map { |file| from_h(Agent::Paths.read_json(file)) }
         .select { |record| ran_since?(record, since) }
    end

    def ran_since?(record, since)
      return true if since.nil?
      Time.parse(record.started_at.to_s) >= since
    rescue ArgumentError, TypeError
      false
    end

    # ---- the predicates Agent::Outcome classifies on ----

    # A timed-out operation is never a success: Agent::Shell killed it, so there
    # is no exit status and no reason to believe it finished what it started.
    def succeeded?(record) = !record.timed_out && record.status == 0

    def failed(records) = Array(records).reject { |record| succeeded?(record) }

    # What the run DID, as one line per operation, for the issue timeline. This
    # is the payload of the whole contract — `reconcile applied 2 transitions`
    # versus `reconcile applied 0` — so an operation that reported nothing says
    # so explicitly rather than rendering as an empty clause.
    def describe(records)
      Array(records).map { |record| "#{record.operation} — #{outcome_phrase(record)}" }.join("; ")
    end

    def outcome_phrase(record)
      return "timed out" if record.timed_out
      return "exited #{record.status}" unless succeeded?(record)
      summary = record.summary.to_s.strip
      summary.empty? ? "ran (reported no effects)" : summary
    end
  end
end
