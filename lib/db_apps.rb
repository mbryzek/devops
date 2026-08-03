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

  attr_reader :name, :database, :role, :repo_dir

  def initialize(name:, database:, role:, repo_dir:)
    @name = name
    @database = database
    @role = role
    @repo_dir = repo_dir
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
  def DbApp.load(name, repo_dir: nil)
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
      :repo_dir => repo_dir || DbApp.default_repo_dir(base)
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

  # Resolve --app / --repo-dir against the directory the command was run from.
  # Returns nil when neither the flag nor the directory names an app, which is
  # the only case where --app is genuinely required.
  #
  # The cwd supplies the checkout ONLY when it is the chosen app's own schema
  # repo: `--app acumen` run from platform-postgresql must not build platform's
  # tree under acumen's name.
  def DbApp.resolve(name: nil, repo_dir: nil, dir: Dir.pwd)
    cwd_name = DbApp.cwd_name(dir)
    name ||= cwd_name
    return nil if name.nil?
    repo_dir ||= DbApp.cwd_repo_dir(dir) if DbApp.base_name(name) == cwd_name
    DbApp.load(name, :repo_dir => repo_dir)
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

  # The [container, port] holding `db`, or nil when no running container has it.
  def find_container_with_db(db)
    running_containers_with_ports.find { |(_name, port)| DbImages.database_exists?(port, db) }
  end
end
