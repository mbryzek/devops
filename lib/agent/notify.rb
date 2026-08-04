require 'open3'
require 'time'
require 'agent/paths'

# Push notifications (design §4.7): openclaw system events on PR ready, gave up,
# and runner offline.
#
# Deliberately the SHORT list. The design goal is that no routine question needs
# ssh into a mini; it is not that every tick announces itself. Anything that
# fires on a healthy idle machine trains Mike to ignore the channel, which costs
# the alerts that matter — the runner-offline one above all.
#
# Best-effort by construction: a missing or failing `openclaw` must never fail a
# tick or strand a lease.
module Agent
  module Notify
    module_function

    def enabled?
      ENV["DEV_AGENT_NO_NOTIFY"].to_s.empty?
    end

    def event(text)
      return false unless enabled?
      _out, status = Open3.capture2e("openclaw", "system", "event", "--text", text, "--mode", "now")
      status.success?
    rescue Errno::ENOENT
      false
    end

    # Notify at most once per (kind, subject) per window. A stale runner is stale
    # for hours, and re-announcing it every 30 seconds would bury it.
    def once(kind, subject, window_seconds: 6 * 3600, now: Time.now, &block)
      state = Agent::Paths.read_json(Agent::Paths.notified_file) || {}
      key = "#{kind}:#{subject}"
      last = state[key] && (Time.parse(state[key]) rescue nil)
      return false if last && (now - last) < window_seconds
      state[key] = now.utc.iso8601
      # Prune anything far outside the longest window so the file cannot grow
      # without bound on a machine that sees many issues.
      state = state.reject { |_, at| (Time.parse(at) rescue now) < now - 30 * 86_400 }
      Agent::Paths.write_json(Agent::Paths.notified_file, state, mode: 0600)
      block.call
    end
  end
end
