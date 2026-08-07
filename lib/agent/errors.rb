require 'time'
require 'agent/paths'

# A small bounded rolling log of recent failures, persisted to
# Agent::Paths.errors_file, keyed by `source`.
#
# `dev agent tick` is a one-shot process (see Agent::Tick) with no in-memory
# continuity between invocations, so "has this failed 3 times in a row" has
# nowhere to live except on disk between ticks. This is that disk.
#
# "Consecutive failures for source X" is deliberately NOT stored as a counter:
# it is DERIVED by counting this source's entries, so recording and reading can
# never drift apart. That makes the eviction rule part of the streak's
# definition — a cap that can evict one source's entry because a DIFFERENT
# source failed makes the derived number mean something other than "how many
# times in a row did X fail".
#
# WHICH IS EXACTLY WHAT IT DID (ISS-742). The cap was 10 entries TOTAL, oldest
# first, while Agent::Tick::ERROR_ESCALATE_AT counts PER SOURCE — two invariants
# written independently and never compared. One tick runs every chore, so
# failures arrive round-robin across the six sources (checkout_pull,
# claude_config, agent_gc, aidirs_prune, claude_db_gc, docker_prune), and
# simulating that against the real code gives:
#
#   3 failing sources   fires once per source, as designed
#   4 failing sources   fires on EVERY round — eviction bounces the count 3→2→3
#   5 or more           NEVER fires — the first entry is always evicted before
#                       the third is appended, so the count tops out at 2
#
# The machine with five chores failing — no network, full disk, dead Docker, no
# claude checkout — is precisely the machine that needs an issue filed, and was
# the one where nothing was.
#
# So the cap is PER SOURCE, and sources are evicted WHOLE. The file is still
# bounded, which is all the total cap was ever there for: at most
# PER_SOURCE_CAP entries for each of the MAX_SOURCES most recently failing
# sources.
module Agent
  module Errors
    # Entries kept per source. Must stay STRICTLY GREATER than
    # Agent::Tick::ERROR_ESCALATE_AT, and the suite asserts that rather than
    # trusting this comment: at exactly the threshold the count would sit on the
    # escalation value forever and re-file every 30 seconds, which is the
    # four-source bug above wearing a different hat.
    #
    # Two entries of headroom past the threshold, so a streak stays visibly
    # ALIVE after the issue is filed for it, and six sources failing at once is
    # still only 30 rows on the runner heartbeat that carries them.
    PER_SOURCE_CAP = 5

    # ...and a bound on the number of sources, because a per-source cap alone
    # bounds this file only for as long as every caller passes one of a fixed
    # set of constants. They all do today (Agent::Tick and Agent::Maintenance
    # name six frozen strings), and the whole of this issue is what happens when
    # an invariant is assumed rather than enforced. Headroom over those six, so
    # adding a chore never silently evicts one.
    MAX_SOURCES = 8

    module_function

    # Append one failure for `source`, evict per the rules above, and return the
    # updated list — the caller derives the streak from what it gets back rather
    # than re-reading (Agent::Tick#record_failure).
    def record(source, message, now: Time.now)
      entry = { "source" => source, "message" => message, "created_at" => now.utc.iso8601 }
      mutate do
        entries = prune(list + [entry])
        write(entries)
        entries
      end
    end

    # Clears every entry for `source` — call this on success, including a
    # failure that recovered via a fallback. A source that just succeeded has
    # no active streak, whatever it had before.
    def clear(source)
      mutate { write(list.reject { |e| e["source"] == source }) }
    end

    def list
      data = Agent::Paths.read_json(Agent::Paths.errors_file)
      entries = data.is_a?(Hash) ? data["errors"] : nil
      entries.is_a?(Array) ? entries : []
    end

    # Consecutive failures for `source`, derived from the list rather than
    # tracked as a separate counter.
    def count(source)
      list.count { |e| e["source"] == source }
    end

    def write(entries)
      Agent::Paths.write_json(Agent::Paths.errors_file, { "errors" => entries }, mode: 0600)
    end

    # Every read-modify-write of the log, serialised on the log's OWN lock.
    #
    # The lock has to live here rather than in the caller because the two callers
    # are the tick's two phases, which hold two DIFFERENT locks and are designed
    # to overlap each other (Agent::Paths.errors_lock). A `clear` that read the
    # list before a concurrent `record` wrote it put back a list without that
    # failure in it: nothing corrupts, since every write is an atomic rename, but
    # a dropped row is a shortened streak — the same escalation this file exists
    # to make fire, made not to.
    #
    # Reads (`list`, `count`) are deliberately NOT locked: a rename is atomic, so
    # a reader always sees one whole generation of the file, never a mix.
    def mutate
      Agent::Paths.with_lock(Agent::Paths.errors_lock, blocking: true) { yield }
    end

    # The last PER_SOURCE_CAP entries of each of the MAX_SOURCES most recently
    # failing sources, in the order they were recorded.
    #
    # Sources are evicted WHOLE. Trimming the oldest row of some other source to
    # make room is what made the derived streak lie in the first place; dropping
    # a source that has not failed in a long time costs its history and leaves
    # every surviving source's count meaning what ERROR_ESCALATE_AT reads it as.
    def prune(entries)
      entries.each_with_index
             .group_by { |entry, _| entry["source"] }
             .values
             .sort_by { |rows| rows.last.last }
             .last(MAX_SOURCES)
             .flat_map { |rows| rows.last(PER_SOURCE_CAP) }
             .sort_by(&:last)
             .map(&:first)
    end
  end
end
