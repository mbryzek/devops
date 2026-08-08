require 'fileutils'
require 'time'
require 'agent/paths'
require 'agent/stream'

# The machine's memory of "the Claude API is refusing to start sessions right
# now" (ISS-1129).
#
# `Agent::Stream.usage_limit` and `Agent::Outcome` between them make ONE refused
# session harmless: the issue goes back to the queue and the attempt is not
# counted. This is what stops the runner doing it thirty more times. A usage
# limit is an account-wide window with a known reset instant, so the very next
# claim is refused too — and on 2026-08-08 the tick claimed straight through
# one, spending three issues' whole retry budget in ninety seconds and touching
# twenty-five more sessions in the same window.
#
# A THROTTLE, not an authority, in exactly the sense of `maintenance_file` and
# `verify_scan_file`: it lives under state_dir, deleting it costs one wasted
# claim, and nothing anywhere waits on it. It bounds only what this box CLAIMS —
# verify jobs are builds on this hardware with no Claude in them, and they go on
# running.
#
# Deliberately NOT on the platform. The limit belongs to the account this
# machine authenticates with, the reset instant comes from the API's own answer
# to this machine, and a fleet-wide flag would need consensus about whose limit
# it was. A runner that knows it is being refused is the whole requirement.
module Agent
  module UsageLimit
    module_function

    # How long to stand down when the refusal carried no `resetsAt`. Short on
    # purpose: the cost of guessing LOW is one refused claim, which is now free,
    # and the cost of guessing HIGH is an idle runner with a full queue.
    DEFAULT_COOLDOWN_SECONDS = 15 * 60

    # A cooldown never runs longer than this however far away the API says the
    # reset is. A clock skew, or a `resetsAt` in some future unit, must not be
    # able to park the fleet for a week.
    MAX_COOLDOWN_SECONDS = 6 * 60 * 60

    # What the API said when it refused this issue's session, or nil. Reads the
    # session log the executor already wrote — there is no second source, and no
    # network call, on this path.
    def detect(number)
      Agent::Stream.usage_limit(Agent::Paths.session_log(number)) ||
        Agent::Stream.usage_limit(Agent::Paths.legacy_claude_log(number))
    end

    # Remember a refusal until the limit resets. Idempotent and last-write-wins:
    # two sessions refused in the same tick record the same window twice, and a
    # later refusal legitimately extends it.
    def record(info, now: Time.now)
      until_time = reset_at(info, now: now)
      Agent::Paths.write_json(file, { "until" => until_time.utc.iso8601,
                                      "recorded_at" => now.utc.iso8601,
                                      "message" => info.is_a?(Hash) ? info["message"] : info.to_s }, mode: 0600)
      until_time
    end

    # The instant this machine may claim again, or nil when it may claim now.
    # An unreadable or unparseable file is "no cooldown": this is a cache, and
    # failing OPEN here is right for the same reason failing closed is right for
    # `paused` — a corrupt throttle file must not be able to stop the fleet, and
    # the worst it costs is one refused session, which is now free.
    def active(now: Time.now)
      until_time = Time.parse(Agent::Paths.read_json(file).to_h["until"].to_s)
      until_time > now ? until_time : nil
    rescue ArgumentError, TypeError
      nil
    end

    def clear = FileUtils.rm_f(file)

    def file = File.join(Agent::Paths.state_dir, "agent-usage-limit.json")

    # The API's own `resetsAt` when it gave one, clamped. A reset already in the
    # past — a stale log re-read, a skewed clock — falls back to the default
    # cooldown rather than to "no cooldown at all", because the thing that just
    # happened is a refusal either way.
    def reset_at(info, now:)
      stated = info.is_a?(Hash) ? info["resets_at"] : nil
      candidate = stated.respond_to?(:utc) && stated > now ? stated : now + DEFAULT_COOLDOWN_SECONDS
      [candidate, now + MAX_COOLDOWN_SECONDS].min
    end
  end
end
