require 'open3'
require 'time'
require 'agent/paths'

# Push notifications (design §4.7): openclaw system events on PR ready, gave up,
# and a session that could not start.
#
# Deliberately the SHORT list. The design goal is that no routine question needs
# ssh into a mini; it is not that every tick announces itself. Anything that
# fires on a healthy idle machine trains Mike to ignore the channel, which costs
# the alerts that matter.
#
# THIS IS A NUDGE CHANNEL, NOT A RECORD (ISS-535). `openclaw` is not installed on
# the runners, so every push this dispatcher has ever attempted has been a no-op
# — `event` rescued Errno::ENOENT, returned false, and nothing ever looked at the
# false. What kept that from losing information is BACKSTOPS below: every kind of
# push carries the same fact somewhere durable on the platform, and the push only
# ever bought attention sooner. That property is what makes it defensible for a
# runner to ship with no notification channel at all, so it is written down and
# pinned by a test rather than left as something each new call site rediscovers.
#
# The one alert with no durable backstop on this side was `runner_offline`, and
# it is gone from here: an offline machine cannot report itself, and a one-runner
# fleet has no peer to report it either, so a runner-local check was the wrong
# place for it by construction. The platform owns it —
# `CheckAgentRunnerHealthProcessor` runs every 15 minutes and emails on the
# crossing tick, off the same `AgentInvariants.StaleAfterHours` this tick used to
# read back as `is_stale`.
#
# Best-effort by construction: a missing or failing `openclaw` must never fail a
# tick or strand a lease. What changed is that best-effort no longer means
# SILENT — `event` says which of the three things happened, and the caller logs
# anything that was not delivered.
module Agent
  module Notify
    BINARY = "openclaw".freeze

    # What this push is, and — the load-bearing half — where the same fact lives
    # when the push does not arrive. A kind with no durable backstop is a kind
    # whose loss is real, and the finding of ISS-535 is that nothing was
    # checking. test_dev_agent_notify.rb asserts this table and the kinds the
    # tick actually pushes are the same set, so a new notification cannot be
    # added without naming what carries it when openclaw is absent.
    BACKSTOPS = {
      "agent_error" => "the same tick files a fingerprinted issue naming the machine and the failing source",
      "pr_ready" => "the issue itself moves to `fixed` with the PR url",
      "merged_pr" => "the issue itself moves to `fixed` with the merged PR url",
      "gave_up" => "the issue itself moves to `needs_input` with the attempt history",
      "playbook_unresolved" => "the issue itself moves to `needs_input` with the unresolved playbook path",
      "toolchain" => "the same check unconditionally files a fingerprinted issue naming the machine and the missing tools",
    }.freeze

    # Delivered. The only outcome not worth a log line.
    DELIVERED = :delivered
    # `openclaw` exists and refused. Transient by assumption — a gateway that is
    # restarting is back in a minute — so the `once` window is NOT consumed and
    # the next tick tries again.
    FAILED = :failed
    # There is no `openclaw` on this machine, which is the ISS-535 state. Not
    # transient: retrying costs a process every 30 seconds and cannot succeed, so
    # the window IS consumed. Silence here was the bug, so the caller logs it
    # with the backstop that carried the fact instead.
    UNAVAILABLE = :unavailable
    # DEV_AGENT_NO_NOTIFY — the test seam, and the switch for a machine that is
    # deliberately quiet. Suppression is a choice someone made, so it needs no
    # report.
    DISABLED = :disabled

    module_function

    def enabled?
      ENV["DEV_AGENT_NO_NOTIFY"].to_s.empty?
    end

    # Where `openclaw` resolves on this machine, or nil. Report-only — `event`
    # decides delivered/undelivered from what actually happened, never from this
    # — so a PATH that differs from the agent's own can mislead a human reading
    # `dev agent status` but can never mislabel a push.
    def channel_path(path: ENV["PATH"])
      path.to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?
        begin
          candidate = File.join(File.expand_path(dir), BINARY)
        rescue ArgumentError
          next # an unexpandable entry (`~` with no HOME) is not a channel
        end
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    # `kind` is not sent anywhere, and it is not dead weight: it is what makes a
    # push impossible to send without naming one, which is what
    # test_dev_agent_notify.rb scans for. Dropping it back to `event(text)` would
    # let a new call site shell out with no entry in BACKSTOPS and nothing to
    # notice — the exact hole this whole file exists to close. Do not tidy it
    # away.
    def event(kind, text)
      return DISABLED unless enabled?
      _out, status = Open3.capture2e(BINARY, "system", "event", "--text", text, "--mode", "now")
      status.success? ? DELIVERED : FAILED
    rescue Errno::ENOENT
      UNAVAILABLE
    end

    def delivered?(outcome) = outcome == DELIVERED

    # Worth a log line: the push did not arrive and nobody asked for that.
    # DISABLED is excluded on purpose — a machine someone silenced reporting its
    # own silence every tick is the noise this module's short list exists to
    # avoid, and it would bury the two outcomes that are actually findings.
    def reportable?(outcome) = outcome == FAILED || outcome == UNAVAILABLE

    # One log line for a push that did not arrive, naming what carries the fact
    # instead. Both halves matter: "undelivered" alone reads as lost, and the
    # backstop alone reads as fine.
    def explain(kind, outcome)
      reason = case outcome
               when UNAVAILABLE then "no `#{BINARY}` on this machine"
               when FAILED then "`#{BINARY}` refused"
               when DISABLED then "DEV_AGENT_NO_NOTIFY is set"
               else return "delivered"
               end
      "not delivered (#{reason}); the fact is recorded anyway — " \
        "#{BACKSTOPS.fetch(kind, "NOTHING: `#{kind}` has no durable backstop (see Agent::Notify::BACKSTOPS)")}"
    end

    # Notify at most once per (kind, subject) per window. A repeatedly failing
    # source fails for hours, and re-announcing it every 30 seconds would bury
    # it.
    #
    # The window is consumed by the ATTEMPT, not by the call — and the difference
    # is the second half of ISS-535. Marking it before the block ran meant a
    # single refusal from `openclaw` silently ate the notification for the whole
    # window, so the one failure mode a retry could actually fix was the one
    # guaranteed never to be retried. `FAILED` now leaves the window open;
    # everything else closes it, including `UNAVAILABLE`, because a machine with
    # no channel will not grow one before the next tick.
    def once(kind, subject, window_seconds: 6 * 3600, now: Time.now, &block)
      state = Agent::Paths.read_json(Agent::Paths.notified_file) || {}
      key = "#{kind}:#{subject}"
      last = state[key] && (Time.parse(state[key]) rescue nil)
      return false if last && (now - last) < window_seconds

      outcome = block.call
      return outcome if outcome == FAILED

      state[key] = now.utc.iso8601
      # Prune anything far outside the longest window so the file cannot grow
      # without bound on a machine that sees many issues.
      state = state.reject { |_, at| (Time.parse(at) rescue now) < now - 30 * 86_400 }
      Agent::Paths.write_json(Agent::Paths.notified_file, state, mode: 0600)
      outcome
    end
  end
end
