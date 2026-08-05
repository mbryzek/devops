require 'time'
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

    ISSUE_TYPES = %w[issue epic].freeze

    # Substituted into a child's title, fingerprint and playbook.
    CHILD_TOKEN = "{child}".freeze

    # Substituted into a fingerprint, epic or plain, and the reason it exists is
    # the wedge it prevents. An issue sits at `fixed` and then `deployed` until
    # Mike verifies it, and both are non-terminal for dedup — so an undated
    # fingerprint stops a NIGHTLY producer filing again until a human clicks
    # verify, turning a daily loop into a roughly weekly one with no error
    # anywhere. Dating the fingerprint says "this is tonight's run", which is
    # what a producer that files unconditionally every night actually means.
    #
    # For an epic the children still carry the real dedup (one fingerprint per
    # app, undated, so an unfinished repo is not re-filed); the epic is just
    # tonight's container.
    DATE_TOKEN = "{date}".freeze

    # An issue in any other status is still "in flight" for dedup purposes — see
    # skip_in_flight?. `fixed` counts as in flight, which is what makes "don't
    # re-file while a PR is open" fall out with no GitHub call at all.
    TERMINAL_ISSUE_STATUSES = %w[verified dismissed].freeze

    # One child issue of an epic, already expanded: the templates in
    # `issue.children` are resolved at PARSE time, one Child per name, so the
    # tick never does string substitution and a broken template fails the next
    # tick instead of at 3:45am.
    Child = Struct.new(:name, :title, :fingerprint, :category, :severity, :body_file, keyword_init: true) do
      # The shared playbook with `{child}` resolved, so one file can carry the
      # exact command each child runs (`--app {child}`) instead of telling the
      # session to read its own title.
      def body_text = body_file && File.read(body_file).strip.gsub(CHILD_TOKEN, name)
    end

    Producer = Struct.new(:key, :schedule, :schedule_text, :check, :file_when, :issue, :command, :body_file,
                          :issue_type, :children, :timezone, keyword_init: true) do
      def files_issue? = file_when != "never"
      def fingerprint  = issue && issue["fingerprint"]
      def epic?        = issue_type == "epic"

      # The playbook this producer ships with its issue, or nil. Read at file
      # time so an edit to the playbook takes effect on the next run without a
      # restart — the registry is re-parsed every tick anyway.
      def body_text = body_file && File.read(body_file).strip

      # This run's fingerprint, with `{date}` resolved in the registry's
      # timezone. A fingerprint carrying no token is returned unchanged, which is
      # every producer that dedups on the CONDITION it found rather than on the
      # night it ran.
      def fingerprint_at(now)
        return fingerprint unless fingerprint.to_s.include?(DATE_TOKEN)
        date = Agent::Schedule.in_zone(timezone) { now.getlocal.strftime("%Y-%m-%d") }
        fingerprint.gsub(DATE_TOKEN, date)
      end
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

      producers = entries.map { |entry| build(entry, path, timezone) }
      keys = producers.map(&:key)
      dupes = keys.tally.select { |_, n| n > 1 }.keys
      raise ConfigError, "#{path}: duplicate producer key(s): #{dupes.join(', ')}" unless dupes.empty?

      { timezone: timezone, producers: producers }
    end

    def build(entry, path, timezone = nil)
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
        body_file: resolve_body_file(issue, key, path),
        issue_type: issue_type(issue, key, path),
        children: build_children(issue, key, path),
        timezone: timezone,
      )
    rescue Agent::Schedule::ParseError => e
      raise ConfigError, "#{path}: #{entry.is_a?(Hash) ? entry['key'] : '?'}: #{e.message}"
    end

    # `issue.type` — `issue` (the default) or `epic`.
    #
    # An epic files a CONTAINER plus one child per name in `issue.children`, and
    # the children are what a session claims and works. It exists for the run
    # that is really N independent runs: the nightly dependency upgrade is six
    # repos, each with its own clone, its own suite and its own PR, and as one
    # issue a single wedged repo took the whole night with it. As six children it
    # is six leases, six retries and six separately visible outcomes, with one
    # thing for Mike to verify at the end.
    def issue_type(issue, key, path)
      return "issue" unless issue.is_a?(Hash)
      type = (issue["type"] || "issue").to_s
      raise ConfigError, "#{path}: #{key}: issue.type must be one of #{ISSUE_TYPES.join(', ')}" unless ISSUE_TYPES.include?(type)
      raise ConfigError, "#{path}: #{key}: issue.type: epic requires an issue.children block" if type == "epic" && !issue["children"].is_a?(Hash)
      raise ConfigError, "#{path}: #{key}: issue.children is only meaningful with issue.type: epic" if type != "epic" && issue["children"]
      type
    end

    # Expands `issue.children` into one concrete Child per name.
    #
    #   children:
    #     names: [platform, acumen]
    #     category: infrastructure
    #     title: "Dependency upgrades: {child}"
    #     fingerprint: "dependencies:upgrade:{child}"
    #     body_file: bodies/dependency-upgrade-app.md
    #
    # Templates rather than N literal blocks because every child of an epic is
    # the same job pointed at a different target — N blocks would be N copies to
    # keep in sync, which is how one of them silently stops matching the others.
    # `{child}` is REQUIRED in both title and fingerprint: without it in the
    # fingerprint every child would dedup against its siblings and only the first
    # would ever be filed.
    def build_children(issue, key, path)
      spec = issue.is_a?(Hash) ? issue["children"] : nil
      return [] unless spec.is_a?(Hash)

      names = spec["names"]
      raise ConfigError, "#{path}: #{key}: issue.children.names must be a non-empty list" unless names.is_a?(Array) && !names.empty?
      dupes = names.map(&:to_s).tally.select { |_, n| n > 1 }.keys
      raise ConfigError, "#{path}: #{key}: duplicate child name(s): #{dupes.join(', ')}" unless dupes.empty?

      %w[title fingerprint category].each do |field|
        raise ConfigError, "#{path}: #{key}: issue.children.#{field} is required" if spec[field].to_s.empty?
      end
      %w[title fingerprint].each do |field|
        next if spec[field].to_s.include?(CHILD_TOKEN)
        raise ConfigError, "#{path}: #{key}: issue.children.#{field} must contain #{CHILD_TOKEN} or every child would be identical"
      end

      body_file = resolve_body_file(spec, "#{key} (children)", path)
      names.map do |name|
        Child.new(
          name: name.to_s,
          title: spec["title"].gsub(CHILD_TOKEN, name.to_s),
          fingerprint: spec["fingerprint"].gsub(CHILD_TOKEN, name.to_s),
          category: spec["category"].to_s,
          severity: spec["severity"],
          body_file: body_file,
        )
      end
    end

    # `issue.body_file` names a playbook that ships with the issue, resolved
    # under `agent/` and read when the issue is filed.
    #
    # A file rather than an inline `body:` because the playbooks that need this
    # are long and shared: every weekly-review producer points at the SAME
    # playbook, so inlining it would mean one copy per repo, drifting the moment
    # anyone edits one of them.
    #
    # Validated HERE, at parse time, rather than at file time. A producer with a
    # typo'd path would otherwise stay silent until its schedule came round —
    # `file_when: always` producers fire weekly, so the mistake would surface at
    # 2am, a week late, as an issue whose brief is just missing.
    def resolve_body_file(issue, key, path)
      return nil unless issue.is_a?(Hash)
      rel = issue["body_file"].to_s
      return nil if rel.empty?
      raise ConfigError, "#{path}: #{key}: issue.body_file must be relative to agent/, not absolute" if rel.start_with?("/")

      resolved = File.expand_path(rel, Agent::Paths.agent_dir)
      raise ConfigError, "#{path}: #{key}: issue.body_file not found: #{rel}" unless File.file?(resolved)
      resolved
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

    # The registry as this machine reads it, in the shape the platform stores as
    # REPORTED STATE (`PUT /agent/registry/:runner_id`).
    #
    # The arithmetic is the same `Agent::Schedule.next_due` that `dev agent
    # producers` prints, and it stays HERE for the reason the whole subsystem is
    # arranged this way: the server does not know the grammar and must not learn
    # it. What the platform gets is a conclusion, not a schedule to evaluate.
    #
    # Reporting it is what makes "should have run and did not" visible at all.
    # Run history alone cannot show it -- a producer that has stopped firing and
    # one that simply had nothing to do produce the same silence, and a producer
    # no live machine schedules anymore produces no rows at all.
    def report(registry, last_run_by_key:, now: Time.now)
      timezone = registry.fetch(:timezone)
      registry.fetch(:producers).map do |producer|
        next_due = Agent::Schedule.next_due(producer.schedule, last_run_at: last_run_by_key[producer.key],
                                            now: now, timezone: timezone)
        {
          producer_key: producer.key,
          # The authored text, not the parsed structure: two machines on
          # different devops shas are meant to be comparable by eye.
          schedule: producer.schedule_text,
          next_due_at: (next_due || now).utc.iso8601,
        }
      end
    end
  end
end
