require 'time'
require 'agent/credentials'
require 'agent/paths'
require 'newrelic'
require 'newrelic_ingest'

# The daily half of ISS-1077: something that actually WATCHES what the account
# ingests, rather than a number somebody measured once and wrote down.
#
# WHY A TICK CHECK AND NOT A PRODUCER. Every other scheduled thing in this fleet
# is a producer — a registry row, arbitrated server-side by a daily
# compare-and-set — and that is the right home for most of them. It is not
# available here: producer rows are created at /admin/agents by a human, so
# shipping this as a producer means shipping code that nothing runs until
# somebody opens a browser, which is the ISS-396 failure with extra steps. A tick
# check is live on every runner the moment the PR merges, because every runner
# fast-forwards its devops checkout at the top of every tick.
#
# WHY RUNNING IT ON EVERY RUNNER IS NOT N TIMES THE WORK. `Agent::Maintenance`
# argues at length that a FLEET-WIDE fact belongs behind fleet-wide arbitration
# and a MACHINE-LOCAL one does not. Ingest is emphatically fleet-wide, so that
# argument says this wants arbitration — and it gets it, just not from a lock:
# the check is a read, so N runners running it cost N cheap NerdGraph queries a
# day and nothing else, and the WRITE is deduplicated by the platform's
# fingerprint rule, which refuses to file while a non-terminal issue with the
# same fingerprint exists. One issue for the fleet, no lock, and no dependence on
# some elected machine being awake. The cadence marker is machine-local for the
# same reason `Agent::Toolchain`'s is: it is a throttle, not an authority.
#
# WHAT HAPPENS WHEN THE KEY IS ABSENT, stated because the alternative is the bug
# this whole file descends from. A runner with no `NEWRELIC_USER_KEY` cannot run
# the check, and `Newrelic.nrql` REFUSES rather than querying unauthenticated —
# because an unauthenticated NerdGraph read returns an empty result set that is
# indistinguishable from a healthy account (ISS-635). So this skips, loudly, in
# the tick's decision log, and `dev agent doctor` already lists the credential's
# presence per machine. It does not file an issue about its own key: a runner
# that cannot reach the env repo has a broader problem than this check, and
# every OTHER runner still measures the same account.
module Agent
  module NewrelicWatch
    # Daily. The subject moves on the order of GB per day and the levers act over
    # weeks, so a tighter cadence would buy nothing and a looser one could miss a
    # step change (a new application starting to report) for most of a month.
    CADENCE_SECONDS = 24 * 3600

    module_function

    def state = Agent::Paths.read_json(Agent::Paths.newrelic_ingest_file)

    def last_check_at(record = state)
      at = record && record["at"]
      at && (Time.parse(at) rescue nil)
    end

    # A machine that has never checked is due immediately, which is what gives a
    # freshly provisioned runner an answer on its first tick rather than a day
    # later.
    def due?(now: Time.now)
      last = last_check_at
      last.nil? || (now - last) >= CADENCE_SECONDS
    end

    # The credential, or nil. Goes straight into `NewrelicIngest.measure` and is
    # never assigned to anything longer-lived, logged, or put on a command line —
    # this runner is shared and a command line is public (ISS-961).
    def key(env: ENV)
      credential = Agent::Credentials::CREDENTIALS.find { |c| c.name == Newrelic::KEY_ENV }
      return nil if credential.nil?

      status, value, _source = Agent::Credentials.probe(credential, env: env)
      status == :present ? value : nil
    end

    # Stamped on EVERY completed pass including a clean one, and including one
    # that could not run. "Ran and found nothing" and "never ran" are the same
    # silence otherwise, which is the failure ISS-531 is about; here the marker is
    # what makes the difference readable on the machine.
    def record(measurement, now: Time.now, skipped: nil)
      Agent::Paths.write_json(
        Agent::Paths.newrelic_ingest_file,
        {
          "at" => now.utc.iso8601,
          "skipped" => skipped,
          "verdict" => measurement&.verdict&.to_s,
          "projected_gb" => measurement&.projected_gb,
          "free_limit_gb" => measurement&.free_limit_gb,
        }.compact,
        mode: 0600,
      )
    end

    def measure(key:, now: Time.now)
      NewrelicIngest.measure(key: key, now: now)
    end
  end
end
