require 'time'
require 'agent/api'
require 'agent/dependency'
require 'agent/paths'

# The way back from a dependency deferral that does not take a day (ISS-922).
#
# An issue blocked on an unmerged fix PR is put down by Agent::Tick#defer_for_
# dependency for DEPENDENCY_DEFER_DAYS — one day — and it DOES come back on its
# own: the snooze expires, the next tick re-runs the Agent::Dependency gate
# against GitHub, and if the PR merged it dispatches. What it does not do is come
# back PROMPTLY. The wake is up to 24 hours after the merge it was waiting for,
# and merges land continuously. ISS-858 sat deferred with platform#2190 already
# merged until Mike cleared the snooze by hand.
#
# So this asks the question again, on a few-minute cadence, for the issues that
# are ALREADY DEFERRED — and only those. That is what makes it a different thing
# from the every-tick recheck DEPENDENCY_DEFER_DAYS deliberately rejects: the
# comment there is about re-asking GitHub for every issue in the queue every 30
# seconds, which would burn a lease and a `gh` call to learn the same thing all
# day. This touches a set that is normally 0-3 rows fleet-wide, holds no lease,
# and starts nothing.
#
# MERGED TO MAIN is the trigger, not deployed. That is exactly what the gate
# reads, and building on merged-but-undeployed code is what the gate permits —
# a wake condition stricter than the gate would leave issues parked that the
# claim behind them would have dispatched on sight.
#
# THE BACKSTOP HALF. The merge lane (Agent::MergeLane, ISS-754) is not the only
# thing that merges in this fleet, it is only the automated one — most PRs still
# land by hand in GitHub's UI, where nothing local observes them. Waking off the
# lane is a fast path with no polling (ISS-923) and it covers a fraction of the
# merges; this covers all of them, a few minutes later.
#
# FAIL OPEN, in the direction that means "leave it alone". Agent::Dependency's
# unknowns dispatch, because a gate that stalls the queue whenever GitHub is
# unreachable is the worse failure. The same policy read from this side is the
# opposite ACT: an unreadable GitHub is not evidence of a merge, so the snooze
# stays and the daily expiry — which has always been there — still brings the
# issue back. See Agent::Dependency.cleared?, which is where that asymmetry is
# argued and enforced.
module Agent
  module DependencyWake
    # How often a runner re-asks. NOT every tick: the tick fires every 30 seconds
    # and a pass costs one list call plus a timeline read per deferred issue, so
    # tick cadence would spend ~700 API calls an hour per box to notice something
    # that is being compared against a 24-hour baseline. Five minutes takes the
    # worst-case wake latency from a day to the length of a coffee refill, which
    # is far inside the time it takes anyone to act on a dispatched issue.
    SWEEP_INTERVAL_SECONDS = 5 * 60

    # How many snoozed issues one pass will look at. A bound rather than a
    # policy: the real set is 0-3, and this exists so that a tracker which
    # somehow accumulates a hundred snoozed issues cannot turn a five-minute
    # chore into a hundred API calls. What is dropped is NAMED by the caller
    # rather than silently truncated, and the next pass takes the next batch.
    CANDIDATE_CAP = 25

    # What one pass did, in the vocabulary the tick logs:
    #   woken   — deferrals lifted (issue numbers)
    #   blocked — dependency-deferred and STILL blocked; left alone
    #   skipped — snoozed for some other reason; not this sweep's business
    #   failed  — cleared, but the platform refused the wake
    #   dropped — candidates past CANDIDATE_CAP, deferred to the next pass
    #   truncated — the list page filled, so there may be snoozed issues this
    #               pass never saw
    Result = Struct.new(:woken, :blocked, :skipped, :failed, :dropped, :truncated, keyword_init: true) do
      def examined = woken.length + blocked.length + failed.length
    end

    module_function

    # ---- cadence (runner-local, same shape as Agent::Verify's lane scan) ----

    def due?(now: Time.now, file: Agent::Paths.dependency_wake_file, interval: SWEEP_INTERVAL_SECONDS)
      last = Agent::Paths.read_json(file)
      at = last && last["at"]
      parsed = (Time.parse(at) if at) rescue nil
      parsed.nil? || (now - parsed) >= interval
    end

    def mark_swept(now: Time.now, file: Agent::Paths.dependency_wake_file)
      Agent::Paths.write_json(file, { "at" => now.utc.iso8601 })
    end

    # ---- the pass ----

    # Every deferred issue whose blockers have landed, woken. Returns a Result;
    # raises nothing that the tick's own work-phase rescue does not already
    # contain, and writes nothing under `dry_run`.
    def sweep(use_localhost:, dry_run: false, cap: CANDIDATE_CAP)
      rows = Agent::Api.snoozed_issues(use_localhost: use_localhost)
      result = Result.new(woken: [], blocked: [], skipped: [], failed: [],
                          dropped: [rows.length - cap, 0].max,
                          truncated: rows.length >= Agent::Api::ISSUES_PAGE_LIMIT)

      rows.first(cap).each do |row|
        number = row["number"]
        # THE FILTER, and it is a timeline read rather than anything on the row:
        # a snooze carries no reason, so "was this deferred by the dispatcher, or
        # by a human parking it until the data migration finishes" is a question
        # only the comment the dispatcher wrote can answer. Waking somebody
        # else's snooze would be this sweep undoing a deliberate decision it
        # knows nothing about.
        unless dependency_deferred?(number, use_localhost: use_localhost)
          result.skipped << number
          next
        end

        # The FULL issue, never the list row, and the difference is a silent
        # failure mode rather than a style choice: `cleared?` reads `links`, and
        # an issue with no blockers is vacuously cleared. A list row that stopped
        # carrying links would therefore read as "every deferral is cleared" and
        # this would unsnooze the lot. The single-issue read is the same one the
        # claim-time gate uses, so if it ever stops answering, the gate is
        # already wrong in the same direction and far more loudly.
        issue = read_issue(number, use_localhost: use_localhost)
        next if issue.nil?
        # Somebody got there first — another runner's sweep, an expiry, a human.
        # The wake itself is idempotent, but the note beside it is not, and a
        # timeline saying the same thing twice is the kind of noise that makes a
        # timeline stop being read.
        next if issue["snoozed_until"].to_s.empty?

        unless Agent::Dependency.cleared?(issue, use_localhost: use_localhost)
          result.blocked << number
          next
        end

        # One issue the platform refuses does not cost the rest of the pass, and
        # it is not counted as woken either — a Result that overstates what
        # happened is how a silent failure gets reported as a success.
        if dry_run || lift(number, use_localhost: use_localhost)
          result.woken << number
        else
          result.failed << number
        end
      end

      result
    end

    # Has the dispatcher deferred this issue on a dependency? The marker on the
    # timeline is the record — see Agent::Dependency::DEFER_MARKER for why the
    # count lives in a comment and not in a field.
    #
    # A timeline that cannot be read answers false: not knowing why an issue is
    # snoozed is the case where leaving it snoozed is obviously right.
    def dependency_deferred?(number, use_localhost:)
      comments = begin
        Agent::Api.issue_comments(number, use_localhost: use_localhost)
      rescue StandardError
        []
      end
      comments.any? { |c| c["body"].to_s.include?(Agent::Dependency::DEFER_MARKER) }
    end

    def read_issue(number, use_localhost:)
      Agent::Api.issue(number, use_localhost: use_localhost)
    rescue StandardError
      nil
    end

    # Lift the deferral and say why, in that order. The wake is the thing that
    # matters, so it goes first: a note that could not be posted leaves an issue
    # correctly back in the queue, while the reverse leaves a timeline claiming a
    # wake that never happened.
    #
    # Which is also why only the WAKE decides the answer. A note that fails after
    # a wake that succeeded is an issue that is genuinely back in the queue with
    # nothing on its timeline saying why — cosmetic, and reporting it as a
    # failure would be the sweep lying in the safe-looking direction.
    def lift(number, use_localhost:)
      Agent::Api.wake(number, use_localhost: use_localhost)
      begin
        Agent::Api.comment(number, note, use_localhost: use_localhost)
      rescue StandardError
        nil
      end
      true
    rescue StandardError
      false
    end

    # The timeline note. It carries Agent::Dependency::WAKE_MARKER, which is what
    # resets the consecutive-deferral count — a wake driven by an observed merge
    # must not leave an issue closer to the seven-attempt escalation than it was
    # before it was ever deferred.
    #
    # And it must NOT contain DEFER_MARKER, which is the same mechanism pointed
    # the other way: `defer_attempts` counts comments containing that string, so
    # a wake note that quoted the deferral it was undoing would count itself as
    # another attempt. Asserted by the suite rather than left to whoever edits
    # this next.
    def note
      "#{Agent::Dependency::WAKE_MARKER}.\n\n" \
        "Every issue this one is blocked by now has a fix GitHub reports as merged, so the code it " \
        "builds on is on `origin/main` and there is nothing left to wait for. Woken here rather than " \
        "at the end of its deferral, which could have been most of a day after the merge.\n\n" \
        "Nothing to do: this is back in the queue and the next tick can claim it. The same check runs " \
        "again at claim time, so if this is somehow early the claim simply defers it once more."
    end
  end
end
