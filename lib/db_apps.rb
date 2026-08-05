require 'shellwords'

# One Scala project's schema repo, and the Docker image built from it.
#
# Every Scala project follows the same shape: a `<app>-postgresql` repo of
# schema-evolution-manager scripts, a Postgres database, and a role that owns
# it. That is enough to derive everything the session-DB tooling needs, so
# NOTHING here is hardcoded per app:
#
#   database / role  <- the devops config that already describes them
#                       (dist/<app>.config.json -> scala.development.database).
#                       bin/db has read it for years; this reads the same field
#                       rather than inventing a second place to name a database.
#   image name       <- the database name (platformdb, acumendb) — what the
#                       registry already holds.
#   container/template/session naming <- derived from the database name, which
#                       is what keeps platform's existing "platformdb-claude-*"
#                       containers and "platformdb_sess_*" databases valid
#                       across this change. No flag day.
#   baseline tag     <- docker/baseline-tag in the schema repo, because it moves
#                       with that repo and nothing else can know it.
#
# Adding a Scala project therefore requires no change here: give it a scala
# database config and a ~/code/<app>-postgresql checkout and it appears.
class DbApp
  POSTGRESQL_SUFFIX = "-postgresql".freeze
  CODE_DIR          = File.expand_path("~/code")

  # Schema artifacts baked into the image, at conventional paths inside the
  # schema repo. `journal_settings` is optional — platform has a journal schema
  # and acumen does not, and that difference is expressed by the file being
  # absent rather than by a per-app flag anywhere in this tooling.
  ARTIFACTS = {
    :schema       => "docker/baseline-schema.sql",
    :seed         => "docker/seed.sql",
    :sem_tracking => "docker/sem-tracking.sql",
    :journal      => "docker/baseline-journal-settings.sql"
  }.freeze

  BASELINE_TAG_FILE = "docker/baseline-tag".freeze

  # schema-evolution-manager's migration scripts, and the table it records the
  # applied ones in. Both are SEM's own layout, not ours.
  SCRIPTS_DIR   = "scripts".freeze
  SEM_SCRIPTS_TABLE = "schema_evolution_manager.scripts".freeze

  attr_reader :name, :database, :role, :repo_dir, :repo_source

  # Where `repo_dir` CAME FROM, which is a different question from what it is —
  # and the one that decides whether the tooling may replace it:
  #
  #   :explicit  --repo-dir, or a direct construction: the caller named it.
  #   :cwd       the command was run inside this app's schema repo.
  #   :sibling   a clone of it sits next to the cwd (a feature dir's own).
  #   :default   nothing pointed anywhere, so ~/code/<app>-postgresql was
  #              assumed. NOBODY chose this one, which is what makes it the only
  #              one safe to swap out — see SchemaMirror.
  #   :mirror    the tooling's own clone, pinned to origin/main.
  REPO_SOURCES = [:explicit, :cwd, :sibling, :default, :mirror].freeze

  def initialize(name:, database:, role:, repo_dir:, repo_source: :explicit)
    # Fail loud on a typo. A misspelled source is not inert: `claude-db` decides
    # whether it may substitute a current checkout by comparing against
    # :default, so an unrecognised symbol would silently turn the substitution
    # off and take the stale-checkout bug back with it.
    unless REPO_SOURCES.include?(repo_source)
      raise ArgumentError, "unknown repo_source #{repo_source.inspect} (one of #{REPO_SOURCES.join(', ')})"
    end
    @name = name
    @database = database
    @role = role
    @repo_dir = repo_dir
    @repo_source = repo_source
  end

  # The same app reading its schema from somewhere else.
  def with_repo_dir(dir, repo_source:)
    DbApp.new(:name => name, :database => database, :role => role,
              :repo_dir => dir, :repo_source => repo_source)
  end

  # ── construction ──────────────────────────────────────────────────────────

  # "acumen" and "acumen-postgresql" both name the acumen app.
  def DbApp.base_name(name)
    name.to_s.sub(/#{Regexp.escape(POSTGRESQL_SUFFIX)}\z/, "")
  end

  def DbApp.default_repo_dir(base)
    File.join(CODE_DIR, "#{base}#{POSTGRESQL_SUFFIX}")
  end

  # `repo_dir` overrides the ~/code checkout — a release (or a feature branch
  # under ~/code/ai) builds from the checkout it is running in, not Mike's.
  def DbApp.load(name, repo_dir: nil, repo_source: nil)
    base = DbApp.base_name(name)
    config = Config.load(base)
    scala = config.scala
    if scala.nil?
      Util.exit_with_error("App #{base} has no scala config, so it has no database to build an image from")
    end
    db = scala.development.database
    DbApp.new(
      :name => base,
      :database => db.name,
      :role => db.user,
      :repo_dir => repo_dir || DbApp.default_repo_dir(base),
      :repo_source => repo_source || (repo_dir ? :explicit : :default)
    )
  end

  # ── resolving an app from where the command was run ───────────────────────

  # The app the directory names, or nil — "platform" in ~/code/platform-postgresql,
  # in ~/code/platform, and in a feature clone of either under ~/code/ai. Only
  # apps that own a schema repo qualify; anything else has no image to build and
  # is a typo rather than an inference.
  def DbApp.cwd_name(dir = Dir.pwd)
    name = Args.default_app(dir)
    return nil if name.nil?
    base = DbApp.base_name(name)
    DbApp.names.include?(base) ? base : nil
  end

  # The schema repo checkout the command was run from, or nil. Inferring the app
  # from a feature clone under ~/code/ai and then reading Mike's ~/code checkout
  # would build a tree the caller never asked about, so the checkout is taken
  # from the same place the name was.
  def DbApp.cwd_repo_dir(dir = Dir.pwd)
    base = File.basename(dir).sub(/\-\d+\.\d+\.\d+\z/, "")
    return nil unless base.end_with?(POSTGRESQL_SUFFIX)
    schema_repo = File.exist?(File.join(dir, BASELINE_TAG_FILE)) ||
                  File.directory?(File.join(dir, "scripts"))
    schema_repo ? dir : nil
  end

  # This app's schema repo checked out ALONGSIDE `dir`, or nil.
  #
  # A session works in ~/code/ai/<feature>/ with one clone per repo, and runs its
  # suite from ~/code/ai/<feature>/<app>. That directory is not itself the schema
  # repo, so cwd_repo_dir declines it and ~/code/<app>-postgresql was used — which
  # is exactly wrong for the case the drift work exists to fix: a branch carrying
  # its OWN migration would sync against main's scripts and silently not get it.
  # Same hermetic-sibling convention `api` uses for apibuilder specs.
  #
  # Both the feature dir itself and a clone inside it qualify, so this resolves
  # from ~/code/ai/<feature> and from ~/code/ai/<feature>/<app> alike.
  def DbApp.sibling_repo_dir(base, dir = Dir.pwd)
    repo = "#{base}#{POSTGRESQL_SUFFIX}"
    parent = File.dirname(dir)
    [File.join(dir, repo), File.join(parent, repo)].each do |candidate|
      found = DbApp.cwd_repo_dir(candidate)
      return found if found
    end
    nil
  end

  # Resolve --app / --repo-dir against the directory the command was run from.
  # Returns nil when neither the flag nor the directory names an app, which is
  # the only case where --app is genuinely required.
  #
  # The cwd supplies the checkout ONLY when it is the chosen app's own schema
  # repo: `--app acumen` run from platform-postgresql must not build platform's
  # tree under acumen's name. Failing that, a clone of it next to the cwd does —
  # see sibling_repo_dir. ~/code/<app>-postgresql is the last resort, not the
  # first, because a session that has its own clone means to use it.
  def DbApp.resolve(name: nil, repo_dir: nil, dir: Dir.pwd)
    cwd_name = DbApp.cwd_name(dir)
    name ||= cwd_name
    return nil if name.nil?
    base = DbApp.base_name(name)
    source = repo_dir ? :explicit : nil
    if repo_dir.nil? && base == cwd_name
      repo_dir = DbApp.cwd_repo_dir(dir)
      source = :cwd if repo_dir
    end
    if repo_dir.nil?
      repo_dir = DbApp.sibling_repo_dir(base, dir)
      source = :sibling if repo_dir
    end
    DbApp.load(name, :repo_dir => repo_dir, :repo_source => source)
  end

  # Every app with a scala database config AND a schema repo checked out. The
  # checkout is part of the test because a deployable can share another app's
  # database (playbook-api is built from platform) — only the app that owns the
  # schema repo owns the image.
  def DbApp.all
    Config.all.select { |a|
      a.scala && File.directory?(DbApp.default_repo_dir(a.name))
    }.map { |a| DbApp.load(a.name) }
  end

  def DbApp.names
    DbApp.all.map(&:name)
  end

  # The app that owns a container name, or nil. Used by the commands that work
  # across every app (status, gc, end) to label what they found.
  def DbApp.for_container(container_name, apps: DbApp.all)
    apps.find { |app| app.owns_container?(container_name) }
  end

  # ── identity ──────────────────────────────────────────────────────────────

  # Registry image name is the database name: registry/bryzek/platformdb.
  def image_name
    database
  end

  def image_ref(tag)
    "#{DbImages::REGISTRY}/#{image_name}:#{tag}"
  end

  # Containers are "<database>-claude-<schema-tag>". The bare prefix is also the
  # name of platform's LEGACY pre-per-tag-split container, which may still hold
  # another session's data — it is listed and (once empty) reaped, never removed
  # by force.
  def container_prefix
    "#{database}-claude"
  end

  def legacy_container
    container_prefix
  end

  def container_name(schema_tag)
    "#{container_prefix}-#{schema_tag}"
  end

  # Schema tag a container name encodes, or nil for the legacy untagged one.
  def container_schema_tag(name)
    return nil if name == legacy_container
    prefix = "#{container_prefix}-"
    return nil unless name.start_with?(prefix)
    tag = name[prefix.length..]
    tag && !tag.empty? ? tag : nil
  end

  def owns_container?(name)
    name == legacy_container || name.start_with?("#{container_prefix}-")
  end

  def template_db
    "#{database}_template"
  end

  def sess_prefix
    "#{database}_sess_"
  end

  # Per-session database name. Sanitisation matches DbImages.sanitize_session_id;
  # the truncation length depends on the prefix, which is why this lives here.
  def session_db_name(sid = nil)
    sid ||= DbImages.session_id
    sanitized = DbImages.sanitize_session_id(sid)
    "#{sess_prefix}#{sanitized[0, DbImages::MAX_IDENTIFIER_LENGTH - sess_prefix.length]}"
  end

  def owns_session_db?(db)
    db.start_with?(sess_prefix)
  end

  # ── schema repo ───────────────────────────────────────────────────────────

  def path(relative)
    File.join(repo_dir, relative)
  end

  # Path to a baked artifact, or nil when the app does not have one.
  def artifact(kind)
    p = path(ARTIFACTS.fetch(kind))
    File.exist?(p) ? p : nil
  end

  def require_repo!
    return if File.directory?(repo_dir)
    Util.exit_with_error(
      "#{name}#{POSTGRESQL_SUFFIX} not found at #{repo_dir}. Clone it first."
    )
  end

  # The tag whose schema is committed as docker/baseline-schema.sql. Every later
  # tag is built by replaying only the scripts added since.
  def baseline_tag
    require_repo!
    file = path(BASELINE_TAG_FILE)
    unless File.exist?(file)
      Util.exit_with_error(
        "#{file} not found — #{name} has no baseline. Create one with:\n" \
        "  db-image baseline --app #{name}"
      )
    end
    tag = File.read(file).strip
    Util.exit_with_error("#{file} is empty") if tag.empty?
    tag
  end

  # Latest released schema tag, from the checkout.
  def current_schema_tag
    require_repo!
    tag = Dir.chdir(repo_dir) { `sem-info tag latest 2>&1`.strip }
    if tag.empty? || tag =~ /error/i
      Util.exit_with_error("Could not resolve schema tag from #{repo_dir}: #{tag}")
    end
    tag
  end

  def current_image_ref
    image_ref(DbImages.image_tag(current_schema_tag))
  end

  # ── schema drift ──────────────────────────────────────────────────────────
  #
  # The image tag is the latest RELEASED schema tag, so an image is behind main
  # by every script merged since that release — and a session's own branch can
  # add more on top. Both are the same thing to SEM: a file in scripts/ that the
  # database has no row for.

  # Every migration script the checkout holds, in the order SEM applies them
  # (filenames are timestamps, so lexical order IS apply order).
  def repo_scripts
    require_repo!
    Dir[File.join(repo_dir, SCRIPTS_DIR, "*.sql")].map { |p| File.basename(p) }.sort
  end

  # True when `db` carries SEM's tracking table.
  #
  # Checked before any drift claim because psql_query swallows errors and hands
  # back an empty list: without this, a database SEM has never touched reads as
  # "zero scripts applied", and the caller would cheerfully replay the entire
  # 800-script history against a full schema. An empty answer must mean empty,
  # not broken.
  def sem_tracking?(port, db)
    DbImages.psql_query(
      port,
      "SELECT to_regclass('#{SEM_SCRIPTS_TABLE}') IS NOT NULL",
      :database => db
    ) == ["t"]
  end

  def applied_scripts(port, db)
    DbImages.psql_query(port, "SELECT filename FROM #{SEM_SCRIPTS_TABLE}", :database => db)
  end

  # Scripts the checkout has and `db` has not applied, in apply order. Call only
  # when sem_tracking? is true.
  def pending_scripts(port, db)
    applied = applied_scripts(port, db).to_set
    repo_scripts.reject { |f| applied.include?(f) }
  end

  # The checkout's HEAD, short — printed alongside a drift count so "up to date"
  # always says up to date WITH WHAT. A session DB is only ever as current as the
  # checkout it was synced from, and that checkout can itself be behind origin.
  def repo_head
    require_repo!
    sha = Dir.chdir(repo_dir) { `git rev-parse --short HEAD 2>/dev/null`.strip }
    sha.empty? ? "unknown" : sha
  end

  # Bring refs/remotes/origin/main up to date, so repo_behind_origin measures
  # against main as it is now. True when the fetch succeeded.
  #
  # This USED to refuse to fetch, on the grounds that ~/code/<app>-postgresql is
  # a human's checkout and a tool running on every `start` has no business
  # writing to it, and hedged the number with "at least". That reasoning was
  # wrong in the way that matters: the count is read from refs/remotes/origin/main,
  # so an unfetched checkout does not report a hedged number, it reports ZERO —
  # and `sync` then prints "up to date with the checkout" over a database that is
  # days behind. A warning that can silently read green is worse than none, and
  # whether it reads green comes down to how recently a human happened to fetch.
  #
  # Fetching touches refs/remotes only — never the working tree, never a local
  # branch — so the objection does not apply to it. Failure (offline, no origin)
  # leaves the stale-ref reading in place and is reported, not swallowed.
  def repo_fetch_origin
    require_repo!
    Dir.chdir(repo_dir) { system("git", "fetch", "--quiet", "origin", :out => File::NULL, :err => File::NULL) }
  end

  # Commits the checkout is behind its own origin/main, or nil when that cannot
  # be determined. The SECOND staleness gap, and the one that survives a sync:
  # syncing makes the database match the CHECKOUT, so a checkout behind main
  # leaves the database behind main by exactly the migrations it has not pulled.
  # Measured live on 2026-08-03 at 3 commits / 3 scripts.
  #
  # Reads refs/remotes/origin/main, so it is only as current as the last fetch —
  # call repo_fetch_origin first and report the number as a floor when that failed.
  def repo_behind_origin
    require_repo!
    out = Dir.chdir(repo_dir) { `git rev-list --count HEAD..origin/main 2>/dev/null`.strip }
    out =~ /\A\d+\z/ ? out.to_i : nil
  end

  # Every migration script origin/main carries, or nil when that cannot be read
  # (no origin, no main, never fetched). Read from the REF, not the working
  # tree, so it costs nothing beyond the fetch repo_fetch_origin already did.
  def origin_scripts
    require_repo!
    out = Dir.chdir(repo_dir) {
      `git ls-tree --name-only origin/main -- #{SCRIPTS_DIR}/ 2>/dev/null`
    }
    names = out.split("\n").map { |p| File.basename(p.strip) }.select { |f| f.end_with?(".sql") }
    # A schema repo always has scripts, so an empty answer means the ref did not
    # resolve rather than "main has no migrations" — and reporting that as "you
    # are missing nothing" is the exact false green this exists to remove.
    names.empty? ? nil : names.sort
  end

  # Migrations origin/main has that THIS CHECKOUT does not, or nil when the
  # comparison cannot be made.
  #
  # This is the drift that actually costs something, and it is not the same
  # thing as repo_behind_origin: a checkout twenty commits behind on README
  # edits runs a perfectly good test suite, while one commit behind on a script
  # is a wall of red. Syncing a database matches it to a CHECKOUT, so whatever
  # is in this list is missing from the database too — and it surfaces later as
  # a missing relation or a not-null violation that reads like the branch's
  # fault (ISS-545, ISS-276).
  #
  # One-directional on purpose: a script the checkout has and main does not is
  # this branch's own migration, which is the normal case and not drift.
  def missing_scripts_vs_origin
    origin = origin_scripts
    return nil if origin.nil?
    have = repo_scripts.to_set
    origin.reject { |f| have.include?(f) }
  end

  # ── docker / postgres, scoped to this app ─────────────────────────────────

  # This app's containers on this box, running or not, sorted by name.
  # `docker ps --filter name=` is a substring match, so the result is filtered
  # against the prefix to keep an unrelated container from being adopted.
  def containers
    out = `docker ps -a --filter name=#{Shellwords.shellescape(container_prefix)} --format '{{.Names}}' 2>/dev/null`
    out.split("\n").map(&:strip).reject(&:empty?).select { |n| owns_container?(n) }.sort
  end

  # Every running container of this app paired with its port, as [name, port].
  # Containers whose port cannot be determined are skipped — there is no way to
  # talk to them and guessing a port would mean talking to somebody else's.
  def running_containers_with_ports
    containers.select { |n| DbImages.container_running?(n) }.map { |n|
      port = DbImages.container_port(n)
      port ? [n, port] : nil
    }.compact
  end

  def list_session_dbs(port)
    DbImages.psql_query(
      port,
      "SELECT datname FROM pg_database WHERE datname LIKE '#{sess_prefix}%' ORDER BY datname"
    )
  end

  def active_session_dbs(port)
    DbImages.psql_query(
      port,
      "SELECT DISTINCT datname FROM pg_stat_activity WHERE datname LIKE '#{sess_prefix}%'"
    ).to_set
  end

  # Age in seconds of each session database, keyed by database name.
  #
  # Postgres stores no creation timestamp for a database, so this reads the mtime
  # of PG_VERSION — a file written once when the database directory is created
  # and never touched again, which makes it the creation time in all but name.
  # Reading it needs the superuser connection psql_query already uses.
  #
  # A database whose age cannot be read is simply ABSENT from the result rather
  # than present with some default. Callers reap on age, so an unreadable age has
  # to mean "keep"; a default of 0 would keep everything (harmless) but a default
  # of infinity would silently drop live sessions' data on any query failure.
  def session_db_ages(port)
    rows = DbImages.psql_query(
      port,
      "SELECT datname || '|' || " \
      "EXTRACT(EPOCH FROM (now() - (pg_stat_file('base/' || oid || '/PG_VERSION')).modification))::bigint " \
      "FROM pg_database WHERE datname LIKE '#{sess_prefix}%'"
    )
    rows.each_with_object({}) do |row, acc|
      name, secs = row.split("|", 2)
      next if name.nil? || secs.nil? || secs.strip.empty?
      acc[name] = secs.to_i
    end
  end

  # Which of `dbs` gc is allowed to drop. Pure, and deliberately separate from
  # the dropping: this predicate IS gc's safety story, so it has to be testable
  # without a live container.
  #
  # A database survives if ANY of these holds — they are independent guards, not
  # a ranking:
  #   * it belongs to the session running gc (current_db)
  #   * something is connected to it right now (active)
  #   * it is younger than the cutoff
  #   * its age could not be read (ages has no entry) — unknown means keep
  def reapable_session_dbs(dbs, active:, ages:, cutoff_seconds:, current_db: nil)
    dbs.select do |db|
      age = ages[db]
      db != current_db && !active.include?(db) && !age.nil? && age >= cutoff_seconds
    end
  end

  # The [container, port] holding `db`, or nil when no running container has it.
  def find_container_with_db(db)
    running_containers_with_ports.find { |(_name, port)| DbImages.database_exists?(port, db) }
  end
end
