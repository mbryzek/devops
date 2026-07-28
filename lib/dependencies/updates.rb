require 'yaml'

# Core logic for `dev dependencies` — parsing sbt-updates output, deciding
# which bumps are allowed (version policy + denylist), and building the
# upgrade prompt for the per-repo Claude session. Pure functions only; all
# process/git/network work stays in bin/dev so this file is fully unit-testable.
module Dependencies
  module Updates
    module_function

    # The repos this command watches. Lib bumps update the lib's own
    # dependencies only — releasing the lib (release-lib) stays manual.
    APPS = {
      "platform"   => "mbryzek/platform",
      "acumen"     => "mbryzek/acumen",
      "lib-util"   => "mbryzek/lib-util",
      "lib-query"  => "mbryzek/lib-query",
      "lib-cipher" => "mbryzek/lib-cipher",
      "lib-ai"     => "mbryzek/lib-ai",
    }.freeze

    # Injected via `sbt --addPluginSbtFile=<file>` so no repo ever has to
    # commit the plugin. Pinned; bump deliberately. sbt 1 and sbt 2 need
    # different releases: 0.6.4 is sbt1-only, 0.7.0 publishes the
    # sbt-updates_sbt2_3 axis (sbt 2 has no built-in dependencyUpdates).
    SBT_UPDATES_PLUGIN = %q{addSbtPlugin("com.timushev.sbt" % "sbt-updates" % "0.6.4")}.freeze
    SBT_UPDATES_PLUGIN_SBT2 = %q{addSbtPlugin("com.timushev.sbt" % "sbt-updates" % "0.7.0")}.freeze

    # How each repo proves a bump is green. platform's suite needs an isolated
    # session DB (never Mike's :5432), and the export must happen in the SAME
    # shell call as sbt — env vars do not persist across separate Bash calls.
    TEST_INSTRUCTIONS = {
      "platform" =>
        "Create an isolated session DB and run the full suite in ONE shell call:\n" \
        "  eval \"$(~/code/devops/bin/claude-db start | grep '^CONF_DB_DEV_URL=' | sed 's/^/export /')\" && sbt test\n" \
        "NEVER point tests at localhost:5432. Note: platform has no sbt CI and main " \
        "can be red — if a failure looks unrelated to any bump, confirm it also fails " \
        "on an unmodified checkout of origin/main (use `git worktree add`, not stash/checkout) " \
        "and if so do NOT defer the bump for it.",
      "acumen" => "Run the suite with `./run.sh test` (uses the local acumendb).",
      "lib-cipher" => "Run the suite with `sbt testQuick` (this repo is on sbt 2, where bare `test` misbehaves).",
    }.freeze
    DEFAULT_TEST_INSTRUCTION = "Run the suite with `sbt test`.".freeze

    def test_instruction(app)
      TEST_INSTRUCTIONS.fetch(app, DEFAULT_TEST_INSTRUCTION)
    end

    # ---------- sbt-updates report parsing ----------

    # Parses `sbt dependencyUpdates` output into
    #   [{group:, artifact:, current:, candidates: [..]}, ...]
    # Report lines look like:
    #   [info]   org.postgresql:postgresql : 42.7.11 -> 42.7.13
    #   [info]   com.foo:bar:test : 1.0.0 -> 1.0.9 -> 1.2.0
    # The module id may carry a trailing config (":test"); the version chain
    # lists newer patch/minor/major candidates left to right. Multi-module
    # builds repeat entries per subproject — dedupe on (group, artifact,
    # current) and union the candidates.
    def parse_report(text)
      found = {}
      text.to_s.each_line do |line|
        left, _sep, right = line.partition(" : ")
        next if right.empty? || !right.include?("->")
        module_id = left.sub(/\A\[info\]\s*/, "").strip
        parts = module_id.split(":")
        next unless parts.length.between?(2, 3) && parts.all? { |p| p.match?(/\A[\w.\-]+\z/) }
        chain = right.split("->").map(&:strip)
        next if chain.length < 2 || chain.any?(&:empty?)
        key = [parts[0], parts[1], chain.first]
        entry = found[key] ||= { group: parts[0], artifact: parts[1], current: chain.first, candidates: [] }
        entry[:candidates] |= chain.drop(1)
      end
      found.values
    end

    # ---------- version policy ----------

    # "Simple" = plain dotted numerics (the old dependency app's isSimple rule).
    # We only ever bump FROM a simple version TO a simple version: prereleases
    # (RC/M/alpha/beta/SNAPSHOT) and date-style or otherwise exotic tags are
    # never auto-upgrade targets, and a dependency currently pinned to a
    # non-simple version is left alone entirely.
    def simple_version?(v)
      v.to_s.match?(/\A\d+(\.\d+)*\z/)
    end

    def version_key(v)
      v.to_s.split(".").map(&:to_i)
    end

    # A leading component of 6+ digits is a datestamp, not a semver major
    # (e.g. commons-codec's infamous `20041127.091804` on Maven Central).
    def date_like?(v)
      v.to_s.split(".").first.to_s.length >= 6
    end

    # Highest stable candidate strictly greater than current, or nil. The
    # date_like check keeps semver-versioned deps from "upgrading" onto
    # datestamp releases and vice versa — shapes must match.
    def choose_target(current, candidates)
      return nil unless simple_version?(current)
      best = candidates
        .select { |c| simple_version?(c) && date_like?(c) == date_like?(current) }
        .max_by { |c| version_key(c) }
      best && (version_key(best) <=> version_key(current)).positive? ? best : nil
    end

    # ---------- denylist ----------

    # denylist.yml shape:
    #   deny:
    #     - artifact: com.google.inject:guice   # group:artifact, required
    #       reason: "6.x breaks Play DI"        # required
    #       versions: ">= 6.0.0"                # optional: ">= X", "> X", "= X", or exact
    #       apps: [platform]                    # optional: default all apps
    def load_denylist(path)
      return [] unless File.exist?(path)
      data = YAML.safe_load(File.read(path)) || {}
      entries = data["deny"] || []
      entries.each do |e|
        raise "denylist entry missing 'artifact': #{e.inspect}" unless e["artifact"]
        raise "denylist entry missing 'reason': #{e.inspect}" unless e["reason"]
      end
      entries
    end

    def version_constraint_matches?(constraint, version)
      return true if constraint.nil? || constraint.to_s.strip.empty?
      c = constraint.to_s.strip
      if (m = c.match(/\A(>=|>|=)\s*(\S+)\z/))
        cmp = version_key(version) <=> version_key(m[2])
        case m[1]
        when ">=" then cmp >= 0
        when ">"  then cmp.positive?
        when "="  then cmp.zero?
        end
      else
        version == c
      end
    end

    def denied_by(entries, app, group, artifact, target)
      key = "#{group}:#{artifact}"
      entries.find do |e|
        e["artifact"] == key &&
          (e["apps"].nil? || e["apps"].include?(app)) &&
          version_constraint_matches?(e["versions"], target)
      end
    end

    # ---------- policy application ----------

    # Splits parsed updates into:
    #   bumps:   [{group:, artifact:, current:, target:}]      — hand to Claude
    #   held:    [{... , reason:}]                             — denylisted
    #   skipped: [{group:, artifact:, current:, candidates:}]  — no stable target
    def apply_policy(updates, denylist_entries, app)
      result = { bumps: [], held: [], skipped: [] }
      updates.each do |u|
        target = choose_target(u[:current], u[:candidates])
        if target.nil?
          result[:skipped] << u
        elsif (entry = denied_by(denylist_entries, app, u[:group], u[:artifact], target))
          result[:held] << u.merge(target: target, reason: entry["reason"])
        else
          result[:bumps] << { group: u[:group], artifact: u[:artifact], current: u[:current], target: target }
        end
      end
      %i[bumps held skipped].each { |k| result[k].sort_by! { |u| [u[:group], u[:artifact]] } }
      result
    end

    # ---------- Claude prompt ----------

    # Bounded like Codegen::Sync.fix_prompt: get the repo to a pushed,
    # review-ready PR and STOP. No review rounds, no rebase, no merge.
    def upgrade_prompt(app:, branch:, bumps:)
      bump_lines = bumps.map { |b| "  - #{b[:group]}:#{b[:artifact]}  #{b[:current]} -> #{b[:target]}" }
      <<~PROMPT
        You are in a fresh clone of #{app} on branch #{branch}. Nightly dependency
        detection found these library updates (already vetted against the version
        policy and denylist):

        #{bump_lines.join("\n")}

        Do exactly this and stop once the PR is open:
        1. Apply every bump: edit ONLY the version strings for the listed
           dependencies in build.sbt (and any *.sbt file that declares them).
           Do not touch scalaVersion, sbt.version, or plugin versions.
        2. Compile everything, then verify. #{test_instruction(app)}
        3. Fix any breakage a bump caused (deprecations, renamed APIs). For a
           major version bump, consult the library's release notes / migration
           guide before fixing. Follow the repo's rules/*.mdc conventions.
        4. If a bump cannot be made green with reasonable effort, REVERT that
           bump only, keep the rest, and list it in the PR body under
           "## Deferred upgrades" with the error summary and a ready-to-paste
           denylist entry in this form:
             - artifact: <group>:<artifact>
               versions: "= <target>"
               reason: "<one line: what broke, date>"
        5. Commit the green tree and push: `git push -u origin #{branch}`.
        6. Open the PR: `gh pr create --draft --head #{branch}` with title
           "Upgrade dependencies" and a body listing every applied bump
           (old -> new, release-notes link for majors) plus any Deferred
           upgrades section. Then run `gh pr ready` to mark it ready.
        Do NOT run code reviews, do NOT rebase, do NOT merge, and never
        force-push. Review happens in Reviewable once the PR exists — stop as
        soon as it does. If NOTHING can be upgraded (every bump reverted),
        do not open a PR; print "ALL BUMPS DEFERRED" and the reasons instead.
      PROMPT
    end
  end
end
