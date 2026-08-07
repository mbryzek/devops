# Keeps an agent-driven sbt run off the shared :5432 dev database.
#
# Every scala project's conf/devtest.conf reads:
#
#   db.default.url = "jdbc:postgresql://localhost/<database>"
#   db.default.url = ${?CONF_DB_DEV_URL}
#
# so a session that never exported CONF_DB_DEV_URL does not fail — it quietly
# writes to Mike's own Postgres.app on :5432. Two sessions doing that at once
# trample each other and his data, and the only symptom is a pile of stale-data
# failures that read as code bugs rather than as the wrong database. That is
# ISS-318: a 247-failure platform run on 2026-08-04 that was green, on the same
# commit, against a session database.
#
# Keyed on the CALLER, never on the port alone. CLAUDECODE is set in every shell
# Claude Code runs and is absent from Mike's, so his runs see no flag, no prompt
# and no behaviour change — :5432 is his database on purpose. Only the runs that
# must never reach it are gated, which is why there is no --allow-dev-db opt-out
# to remember.
#
# platform additionally refuses at application startup
# (core.util.DbLocalUrlChecker). That check is the backstop for anything that
# reaches sbt without going through bin/run; this one is the fast path — it fires
# before a compile, names the command to fix it, and covers every project rather
# than only the one that has the Scala check.
module SessionDb

  # Set by Claude Code in every shell it runs. Its presence means "an agent is
  # driving this", which is the entire trigger condition.
  CLAUDE_MARKER = "CLAUDECODE".freeze

  # The per-session database URL, exported from `claude-db start`.
  SESSION_URL = "CONF_DB_DEV_URL".freeze

  # sbt tasks that boot the application or open a connection. Deliberately not
  # "every invocation": `compile`, `scalafmt` and a bare `set ...` never touch a
  # database, and making a session boot a container before it may compile buys
  # nothing and teaches it to export a bogus URL to get past the guard.
  RUN_TASKS = %w[run runMain].freeze

  def self.agent_session?(env = ENV)
    !env[CLAUDE_MARKER].to_s.strip.empty?
  end

  # Whether any sbt task in `args` would open a database.
  #
  # Tasks arrive in every shape sbt accepts, sometimes several to an argument:
  # `test`, `core/test`, `test:compile`, `"core/testOnly core.FooSpec"`,
  # `"set core / Test / testOptions += ..."`. Splitting each argument on the
  # separators sbt uses and looking at the tokens handles all of them without a
  # pattern per form.
  def self.opens_database?(args)
    args.any? do |arg|
      arg.to_s.split(%r{[\s/:]+}).any? do |token|
        RUN_TASKS.include?(token) || token.downcase.start_with?("test")
      end
    end
  end

  # Whether `args` runs TESTS, as opposed to merely opening a database.
  #
  # Narrower than opens_database? on both sides, and both narrowings matter:
  #
  #   `run` / `runMain` open a database and are NOT tests. They start the
  #   application, against state the developer put there deliberately, and a
  #   reset on that path would wipe it on every restart.
  #
  #   `test:compile` / `Test/compile` start with "test" and are NOT tests. They
  #   compile; opens_database? already lets them through unblocked and there is
  #   nothing for a reset to do. Recognised by the `compile` token sitting in
  #   the same argument, which is the only way the two forms are ever spelled.
  #
  # Everything else that names a test task counts, in every shape sbt accepts it:
  # `test`, `core/test`, `"core/testOnly core.FooSpec"`, `testQuick`.
  def self.test_task?(args)
    args.any? do |arg|
      tokens = arg.to_s.split(%r{[\s/:]+}).map(&:downcase)
      next false if tokens.include?("compile")
      tokens.any? { |token| token.start_with?("test") }
    end
  end

  # The `[port, database]` a session JDBC URL names, or `[nil, nil]` when it is
  # not one this tooling produced. Only ever used to CHECK a URL against a
  # database claude-db located for itself — never to go find one — so an
  # unparseable URL is a mismatch rather than something to recover from.
  def self.parse_url(url)
    match = url.to_s.match(%r{\Ajdbc:postgresql://[^/:]*:(\d+)/([^?\s]+)})
    return [nil, nil] if match.nil?
    [match[1].to_i, match[2]]
  end

  # Whether a JDBC URL names the shared dev database rather than a session one.
  #
  # A session database is a container on its own allocated port (5500-9999), so
  # the port is what distinguishes them. No port at all means 5432, and so does
  # an explicit :5432 — both are Postgres.app, however the host is spelled.
  #
  # This only ever runs under CLAUDECODE, so keying on the port here cannot nag
  # an interactive run the way a port check applied to everyone would.
  def self.shared_default_url?(url)
    port = url.to_s[%r{\Ajdbc:postgresql://[^/]*?:(\d+)}, 1]
    port.nil? || port == "5432"
  end

  # Why this run must not proceed, or nil when it may.
  #
  #   :unset  - CLAUDECODE is set and CONF_DB_DEV_URL is not
  #   :shared - CONF_DB_DEV_URL is set, but resolves to the :5432 dev database
  def self.blocking_reason(sbt_args:, env: ENV)
    return nil unless agent_session?(env)
    return nil unless opens_database?(sbt_args)

    url = env[SESSION_URL].to_s.strip
    return :unset if url.empty?
    return :shared if shared_default_url?(url)

    nil
  end

  def self.message(app:, reason:, url: nil)
    <<~MESSAGE
      ERROR: refusing to run sbt against the shared :5432 dev database.

      #{diagnosis(reason, url)}

      A Claude session must run against its own database. Parallel sessions clobber
      each other and Mike's data, and nothing announces it: the suite does not fail,
      it writes to the wrong place (ISS-318).

      Start one and export it in the SAME bash call as ./run.sh — the environment does
      not persist between calls:

        db_out=$(~/code/devops/bin/claude-db start --app #{app}) || exit 1
        export #{SESSION_URL}=$(printf '%s\\n' "$db_out" | sed -n 's/^#{SESSION_URL}=//p')
        ./run.sh test

      Do NOT use eval "$(claude-db start | grep ... | sed ...)": a command substitution
      reports the exit status of the last command in its pipeline, so it swallows a
      failed start and lands you right back here.

      This fires only under Claude Code (#{CLAUDE_MARKER} is set). Interactive runs are
      unaffected, and there is nothing to opt out of.
    MESSAGE
  end

  def self.diagnosis(reason, url)
    case reason
    when :unset
      "#{SESSION_URL} is not set, so conf/devtest.conf falls back to its literal " \
        "default:\n  jdbc:postgresql://localhost/<database>   (Postgres.app, :5432)"
    when :shared
      "#{SESSION_URL} is set to\n  #{url}\nwhich resolves to :5432 — Postgres.app, " \
        "not a session database. Session databases\nare containers on an allocated " \
        "port (#{DbPorts::RANGE_MIN}-#{DbPorts::RANGE_MAX})."
    else
      raise ArgumentError, "Unknown reason #{reason.inspect}"
    end
  end
end
