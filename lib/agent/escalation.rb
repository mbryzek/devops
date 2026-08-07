require 'time'
require 'agent/api'
require 'agent/errors'
require 'agent/notify'

# "This machine has failed at the same thing three times in a row" — recorded,
# then escalated into a push and a filed issue exactly once.
#
# EXTRACTED FROM Agent::Tick (ISS-763), unchanged. It lived there because the
# tick was the only thing on a runner that could fail repeatedly and unattended;
# CI is now the second (`dev ci preflight`), and its failures are precisely the
# ones with nobody watching — an expired DigitalOcean credential turns every CI
# job on the box red, on PRs that did nothing wrong, and the only signal is a
# wall of red that looks like a code failure. Copying ten lines of escalation
# into the CI path would have given the fleet two alarms with one shape and no
# guarantee they stay in agreement about what "in a row" means.
#
# The streak itself is not stored: Agent::Errors DERIVES it by counting a
# source's entries, which is what keeps recording and reading from drifting
# apart. All this adds is the decision of when a count is worth waking somebody
# for.
module Agent
  module Escalation
    # Fire the moment consecutive failures for a source CROSS this threshold,
    # never again while it stays past it — hence `==` rather than `>=` below. A
    # streak that is already escalated must not re-file every 30 seconds.
    #
    # Agent::Errors::PER_SOURCE_CAP must stay STRICTLY GREATER than this, or a
    # count that SATURATES at the threshold would match that `==` forever. The
    # suite asserts it rather than trusting this comment (ISS-742).
    AT = 3

    module_function

    # Record one failure and escalate on the pass that crosses AT. Returns the
    # source's streak length, so a caller that wants to log it need not re-read.
    #
    # `notifier` is how the push is sent, injected because Agent::Tick wraps
    # Agent::Notify.event in its own logging and that logging is part of what a
    # tick's operator reads. `log` is where anything unprintable-but-worth-saying
    # goes; both default to doing nothing, which is right for a one-shot CLI that
    # has already printed its own report.
    def record(source, message, title:, explain:, host:, now: Time.now, dry_run: false,
               use_localhost: false, notifier: nil, log: nil)
      entries = Agent::Errors.record(source, message, now: now)
      count = entries.count { |e| e["source"] == source }
      if count == AT
        escalate(source, message, count, title: title, explain: explain, host: host, now: now,
                 dry_run: dry_run, use_localhost: use_localhost, notifier: notifier, log: log)
      end
      count
    end

    def escalate(source, message, count, title:, explain:, host:, now:, dry_run:,
                 use_localhost:, notifier: nil, log: nil)
      text = "dev-agent: #{source} has failed #{count} times in a row on #{host} (#{message})"
      Agent::Notify.once("agent_error", source, now: now) do
        notifier ? notifier.call("agent_error", text) : Agent::Notify.event("agent_error", text)
      end
      return if dry_run

      Agent::Api.create_issue(
        {
          title: title.call(host),
          category: "bug",
          fingerprint: "#{source}:#{now.utc.strftime('%Y-%m-%d')}",
          body: "The `#{source}` source has failed #{count} times in a row on #{host}.\n\n" \
                "Last error:\n\n```\n#{message}\n```\n\n#{explain}",
          claim_on_create: false,
        },
        use_localhost: use_localhost,
      )
    rescue SessionExpired, ApiError => e
      # Escalation must never take down the phase — or the CI step — it runs in.
      log&.call("#{source} escalation: could not file an issue (#{e.message})")
    end
  end
end
