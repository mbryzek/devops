require 'time'
require 'agent/paths'

# A small bounded rolling log of recent failures, persisted to
# Agent::Paths.errors_file, keyed by `source`.
#
# `dev agent tick` is a one-shot process (see Agent::Tick) with no in-memory
# continuity between invocations, so "has this failed 3 times in a row" has
# nowhere to live except on disk between ticks. This is that disk.
#
# Bounded to CAP entries TOTAL (not per source), oldest evicted first, so a
# source that fails constantly cannot grow this file without bound — the same
# reasoning as Agent::Notify's pruning. "Consecutive failures for source X" is
# deliberately NOT stored as a counter: it is derived by counting this
# source's entries, so recording and reading can never drift apart.
module Agent
  module Errors
    CAP = 10

    module_function

    # Append one failure for `source`, evicting the oldest entry overall if
    # that would push the list past CAP. Returns the updated list.
    def record(source, message, now: Time.now)
      entries = list + [{ "source" => source, "message" => message, "created_at" => now.utc.iso8601 }]
      entries = entries.last(CAP)
      write(entries)
      entries
    end

    # Clears every entry for `source` — call this on success, including a
    # failure that recovered via a fallback. A source that just succeeded has
    # no active streak, whatever it had before.
    def clear(source)
      write(list.reject { |e| e["source"] == source })
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
  end
end
