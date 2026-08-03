require 'yaml'
require 'agent/paths'
require 'agent/schedule'

# The producer registry: `devops/agent/producers.yml`, parsed and validated.
#
# Producers CREATE work; the dispatcher DOES work (design §4.2). Keeping them
# distinct is what stops the dispatcher drifting back into being a scheduler.
# A producer is a cheap check, never the work itself — it never spawns Claude.
# Where a chore has no cheap check it files unconditionally on a slow cadence
# and the expensive part happens as claimed work.
module Agent
  module Producers
    class ConfigError < StandardError; end

    # What a producer run recorded on the platform. `check_failed` is
    # deliberately distinct from `filed`: a check that CRASHES is not evidence of
    # a problem in the thing being checked, and collapsing the two turns a broken
    # producer into a nightly stream of bogus issues.
    RESULTS = %w[filed recurrence skipped_in_flight nothing_to_do check_failed].freeze

    FILE_WHEN = %w[check_fails always never].freeze

    # An issue in any other status is still "in flight" for dedup purposes — see
    # skip_in_flight?. `fixed` counts as in flight, which is what makes "don't
    # re-file while a PR is open" fall out with no GitHub call at all.
    TERMINAL_ISSUE_STATUSES = %w[verified dismissed].freeze

    Producer = Struct.new(:key, :schedule, :schedule_text, :check, :file_when, :issue, :command, keyword_init: true) do
      def files_issue? = file_when != "never"
      def fingerprint  = issue && issue["fingerprint"]
    end

    module_function

    def load(path = Agent::Paths.producers_file)
      raise ConfigError, "producer registry not found: #{path}" unless File.file?(path)
      parse(File.read(path), path: path)
    end

    def parse(text, path: "(inline)")
      data = YAML.safe_load(text) || {}
      raise ConfigError, "#{path}: top level must be a mapping" unless data.is_a?(Hash)
      timezone = data["timezone"]
      raise ConfigError, "#{path}: `timezone` is required (an IANA zone, e.g. America/New_York)" if timezone.to_s.empty?
      raise ConfigError, "#{path}: `timezone` must be an IANA zone (e.g. America/New_York), not an abbreviation like EDT" unless timezone.include?("/")

      entries = data["producers"]
      raise ConfigError, "#{path}: `producers` must be a list" unless entries.is_a?(Array)

      producers = entries.map { |entry| build(entry, path) }
      keys = producers.map(&:key)
      dupes = keys.tally.select { |_, n| n > 1 }.keys
      raise ConfigError, "#{path}: duplicate producer key(s): #{dupes.join(', ')}" unless dupes.empty?

      { timezone: timezone, producers: producers }
    end

    def build(entry, path)
      raise ConfigError, "#{path}: each producer must be a mapping" unless entry.is_a?(Hash)
      key = entry["key"].to_s
      raise ConfigError, "#{path}: every producer needs a `key`" if key.empty?

      file_when = entry["file_when"].to_s
      raise ConfigError, "#{path}: #{key}: `file_when` must be one of #{FILE_WHEN.join(', ')}" unless FILE_WHEN.include?(file_when)

      issue = entry["issue"]
      if file_when == "never"
        raise ConfigError, "#{path}: #{key}: `file_when: never` cannot carry an `issue` block" if issue
      else
        raise ConfigError, "#{path}: #{key}: `file_when: #{file_when}` requires an `issue` block" unless issue.is_a?(Hash)
        %w[title category fingerprint].each do |field|
          raise ConfigError, "#{path}: #{key}: issue.#{field} is required" if issue[field].to_s.empty?
        end
      end

      # A check is what makes "check first, then file" possible. `file_when:
      # always` is the escape hatch for a chore with no cheap check — the review
      # IS the work — and it is the only form allowed to omit one.
      check = entry["check"]
      raise ConfigError, "#{path}: #{key}: `file_when: #{file_when}` requires a `check` command" if check.to_s.empty? && file_when != "always"
      raise ConfigError, "#{path}: #{key}: `command` and `check` are the same field; use `check`" if entry.key?("command")

      Producer.new(
        key: key,
        schedule: Agent::Schedule.parse(entry["schedule"]),
        schedule_text: entry["schedule"].to_s,
        check: check&.to_s,
        file_when: file_when,
        issue: issue,
      )
    rescue Agent::Schedule::ParseError => e
      raise ConfigError, "#{path}: #{entry.is_a?(Hash) ? entry['key'] : '?'}: #{e.message}"
    end

    # Does a non-terminal issue with this fingerprint already exist? One rule
    # covers the whole lifecycle with no GitHub API call (design §4.2):
    #
    #   open / claimed          queued or being worked      -> skip
    #   needs_review / _input   waiting on a human          -> skip
    #   fixed                   PR open, not merged/deployed-> skip
    #   deployed                awaiting verification       -> skip
    #   verified / dismissed    done                        -> file again if due
    #
    # `fingerprint` on the server is the backstop: even on a double-fire it
    # increments occurrence_count instead of creating a duplicate. This check
    # avoids the noise; the fingerprint makes it impossible to get wrong.
    def in_flight?(issues, fingerprint)
      return false if fingerprint.to_s.empty?
      Array(issues).any? do |issue|
        issue["fingerprint"].to_s == fingerprint.to_s &&
          !TERMINAL_ISSUE_STATUSES.include?(issue["status"].to_s)
      end
    end

    # Producers whose schedule says they should run now, given each key's last
    # recorded run. Ordering is registry order so the log reads like the file.
    #
    # Deliberately takes `last_run_by_key` rather than reaching for the network:
    # the arithmetic is the part worth testing, and the fetch is one call in the
    # tick. (Runner labels / `runs_on` are NOT built — design §4.5 — but nothing
    # here assumes fleet-wide execution beyond the caller's own filter.)
    def due(registry, last_run_by_key:, now: Time.now)
      registry.fetch(:producers).select do |producer|
        Agent::Schedule.due?(producer.schedule,
                             last_run_at: last_run_by_key[producer.key],
                             now: now,
                             timezone: registry.fetch(:timezone))
      end
    end
  end
end
