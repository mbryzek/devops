require 'shellwords'

# Registry + container constants and helpers for the platformdb Docker workflow.
#
# Used by bin/claude-db (per-session DB lifecycle) and any other tooling that
# needs to know where images live or how to talk to a local container.
#
# ONE CONTAINER PER SCHEMA TAG. There is no single container and no fixed port:
# the container is "platformdb-claude-<schema-tag>" and its host port is
# allocated per container (see lib/db_ports.rb). Every helper that talks to
# Postgres therefore takes the port of the container it is addressing.
#
# Why: a single shared container on a single port meant that adopting a new
# image forced `docker rm -f` on it, which destroyed EVERY session's database
# rather than just the caller's (measured: one `claude-db start` wiped four
# other sessions' databases).
module DbImages
  REGISTRY      = "registry.digitalocean.com/bryzek"
  IMAGE_NAME    = "platformdb"

  # Container names are "<CONTAINER_PREFIX>-<schema-tag>". The bare prefix is
  # also the name of the LEGACY pre-split container, which may still be running
  # with other sessions' data in it — it is listed and (once empty) reaped, but
  # never removed by force. No flag day.
  CONTAINER_PREFIX = "platformdb-claude"
  LEGACY_CONTAINER = CONTAINER_PREFIX

  HOST          = "localhost"
  TEMPLATE_DB   = "platformdb_template"
  SESS_PREFIX   = "platformdb_sess_"

  # Mike's main platform-postgresql checkout.  Used to resolve the current
  # schema tag and to self-heal missing images via docker/build-and-push.sh.
  PLATFORM_POSTGRESQL_DIR = File.expand_path("~/code/platform-postgresql")

  # Full image reference for a given schema tag.
  def DbImages.image_ref(tag)
    "#{REGISTRY}/#{IMAGE_NAME}:#{tag}"
  end

  # Resolve the current schema tag by running sem-info inside the
  # platform-postgresql checkout.
  def DbImages.current_schema_tag
    dir = PLATFORM_POSTGRESQL_DIR
    unless File.directory?(dir)
      Util.exit_with_error(
        "platform-postgresql not found at #{dir}. " \
        "Clone it or correct PLATFORM_POSTGRESQL_DIR in lib/db_images.rb."
      )
    end
    tag = Dir.chdir(dir) { `sem-info tag latest 2>&1`.strip }
    if tag.empty? || tag =~ /error/i
      Util.exit_with_error("Could not resolve schema tag from #{dir}: #{tag}")
    end
    tag
  end

  # Docker image tag for a schema tag: the schema tag itself, unmodified.
  # The image ref is "registry.digitalocean.com/bryzek/platformdb:<schema-tag>".
  #
  # KNOWN REGRESSION, accepted deliberately — do NOT "fix" it by reintroducing a
  # derived tag. The image is schema PLUS recipe (docker/seed.sql,
  # docker/initdb/*, the Dockerfile), and the recipe changes WITHOUT a schema
  # release. A bare tag therefore lets a stale image keep serving under an
  # unchanged tag: the registry and every local Docker cache already hold an
  # image for that tag, so a recipe-only change reaches NOBODY until the next
  # schema tag bump.
  #
  # This used to be solved by hashing the recipe into the tag
  # (<schema-tag>-r<hash>, via platform-postgresql's docker/image-tag.sh, now
  # deleted). That hash is gone because the tag is now what names the container:
  # a tag that moved without a schema release meant tearing down the shared
  # container, which destroyed every other session's database. Per-tag
  # containers are worth the trade.
  #
  # Mitigation is discipline: BUMP THE SCHEMA TAG WHEN YOU CHANGE THE RECIPE.
  def DbImages.image_tag(schema_tag)
    schema_tag
  end

  # Image tag for the current schema tag — what every session should be on.
  def DbImages.current_image_tag
    DbImages.image_tag(DbImages.current_schema_tag)
  end

  # Feature directory every Claude session works in, one subdirectory per feature.
  AI_DIR = File.expand_path("~/code/ai")

  # Session identifier used to name the per-session database.
  #
  # Resolution order, each step unique per session by construction:
  #   1. CLAUDE_SESSION_ID, when the caller set it explicitly.
  #   2. the ~/code/ai/<feature> directory the caller is working in — one feature
  #      dir per session, and stable no matter which repo inside it is the cwd.
  #   3. no answer: exit with instructions.
  #
  # There is deliberately NO per-machine fallback. It used to be
  # "#{Etc.getlogin}_#{Socket.gethostname}", which is IDENTICAL for every session
  # on this machine, so parallel sessions silently shared one database — the exact
  # opposite of what this tooling exists to provide, and undetectable until one
  # session's unreleased migration breaks another's test run (2026-07-27: a
  # not-null playbook.clubs.days column from an in-flight branch failed 18 specs
  # in a session that had merged nothing of the sort, making `main` look red).
  # Worse, `Socket.gethostname` is not even stable within one session (DHCP
  # re-registration flipped it from "Michaels-MacBook-Pro" to "Mac"), so `end` and
  # `gc` computed a different name than `start` and silently leaked the database
  # they were asked to reclaim. Failing loudly beats either.
  def DbImages.session_id
    sid = ENV['CLAUDE_SESSION_ID']
    return sid.strip if sid && !sid.strip.empty?
    feature = DbImages.feature_dir_name(Dir.pwd)
    return feature if feature
    Util.exit_with_error(
      "Cannot derive a unique session id, and refusing to share one database across sessions.\n" \
      "Either export CLAUDE_SESSION_ID=<feature-name> first:\n" \
      "  export CLAUDE_SESSION_ID=my-feature\n" \
      "or run this from inside your #{AI_DIR}/<feature> working directory, whose name is used instead."
    )
  end

  # Session id when one can be determined, else nil — for read-only callers (see
  # `claude-db status`) that should report "cannot tell" rather than abort. Every
  # caller that CREATES or DROPS a database uses session_id instead, so a session
  # that cannot name itself can never write to, or reclaim, another one's data.
  def DbImages.session_id_or_nil
    sid = ENV['CLAUDE_SESSION_ID']
    return sid.strip if sid && !sid.strip.empty?
    DbImages.feature_dir_name(Dir.pwd)
  end

  # The <feature> component of a path under AI_DIR, or nil when `path` is
  # somewhere else. Matches the directory itself as well as any repo inside it.
  def DbImages.feature_dir_name(path)
    prefix = "#{AI_DIR}#{File::SEPARATOR}"
    expanded = File.expand_path(path)
    return nil unless expanded.start_with?(prefix)
    name = expanded[prefix.length..].to_s.split(File::SEPARATOR).first
    name && !name.empty? ? name : nil
  end

  # Postgres database name derived from a session ID.
  #
  # Sanitisation rules:
  #   - lowercase
  #   - non-alphanumeric characters → underscore
  #   - collapse consecutive underscores
  #   - strip leading / trailing underscores
  #   - truncate so the total name fits within the 63-character Postgres limit
  def DbImages.db_name(sid = nil)
    sid ||= DbImages.session_id
    sanitized = sid.downcase
                   .gsub(/[^a-z0-9]/, '_')
                   .gsub(/_+/, '_')
                   .sub(/^_+/, '')
                   .sub(/_+$/, '')
    # SESS_PREFIX is 16 chars; Postgres max identifier length is 63
    max_suffix = 63 - SESS_PREFIX.length
    sanitized = sanitized[0, max_suffix]
    "#{SESS_PREFIX}#{sanitized}"
  end

  # True if the given schema tag has a pushed image in the DO registry.
  #
  # Requires doctl to be authenticated.  Exits with an error on unexpected
  # doctl failures (e.g. network error) so callers are never silently misled
  # into thinking a tag is absent when it might just be unreachable.
  def DbImages.registry_tag_exists?(tag)
    require 'json'
    out = `doctl registry repository list-tags #{IMAGE_NAME} --output json 2>&1`
    unless $?.success?
      Util.exit_with_error("doctl registry list-tags failed: #{out.strip}")
    end
    (JSON.parse(out) || []).any? { |entry| entry["tag"] == tag }
  rescue JSON::ParserError => e
    Util.exit_with_error("Could not parse doctl registry output: #{e.message}")
  end

  # True if the image exists in the local Docker image cache.
  def DbImages.image_available_locally?(image)
    system("docker image inspect #{Shellwords.shellescape(image)} > /dev/null 2>&1")
  end

  # ── containers ────────────────────────────────────────────────────────────

  # Container name for a schema tag.
  def DbImages.container_name(schema_tag)
    "#{CONTAINER_PREFIX}-#{schema_tag}"
  end

  # Schema tag a container name encodes, or nil for the legacy untagged one.
  def DbImages.container_schema_tag(name)
    return nil if name == LEGACY_CONTAINER
    prefix = "#{CONTAINER_PREFIX}-"
    return nil unless name.start_with?(prefix)
    tag = name[prefix.length..]
    tag && !tag.empty? ? tag : nil
  end

  # Every platformdb-claude* container on this box, running or not, sorted by
  # name. Includes the legacy untagged container when it is still around.
  # `docker ps --filter name=` is a substring match, so the result is filtered
  # against the prefix to keep an unrelated container from being adopted.
  def DbImages.claude_containers
    out = `docker ps -a --filter name=#{CONTAINER_PREFIX} --format '{{.Names}}' 2>/dev/null`
    out.split("\n").map(&:strip).reject(&:empty?)
       .select { |n| n == LEGACY_CONTAINER || n.start_with?("#{CONTAINER_PREFIX}-") }
       .sort
  end

  # True when the named container exists at all (running or stopped).
  def DbImages.container_exists?(name)
    system("docker inspect #{Shellwords.shellescape(name)} > /dev/null 2>&1")
  end

  # True when the named container is up and running.
  def DbImages.container_running?(name)
    out = `docker inspect #{Shellwords.shellescape(name)} --format='{{.State.Running}}' 2>/dev/null`.strip
    out == "true"
  end

  # Image the named container was created from (e.g. "registry.…/platformdb:0.3.44").
  def DbImages.container_image(name)
    `docker inspect #{Shellwords.shellescape(name)} --format='{{.Config.Image}}' 2>/dev/null`.strip
  end

  # Host port the named container publishes Postgres on, or nil.
  #
  # Read from HostConfig.PortBindings rather than NetworkSettings.Ports so a
  # STOPPED container still answers — that is what lets `start` recreate a dead
  # container for the same tag on its original port without being handed one.
  def DbImages.container_port(name)
    out = `docker inspect #{Shellwords.shellescape(name)} \
--format='{{with index .HostConfig.PortBindings "5432/tcp"}}{{(index . 0).HostPort}}{{end}}' 2>/dev/null`.strip
    return nil if out.empty?
    port = out.to_i
    port > 0 ? port : nil
  end

  # ── postgres ──────────────────────────────────────────────────────────────
  #
  # Every one of these takes the port of the container being addressed. There is
  # no default: a constant here is exactly how one session ends up talking to
  # another session's container.

  # Block until Postgres on `port` accepts connections, or exit with an error.
  def DbImages.wait_for_postgres(port, timeout: 30)
    deadline = Time.now + timeout
    loop do
      system("pg_isready -h #{HOST} -p #{port} -q > /dev/null 2>&1")
      return if $?.success?
      Util.exit_with_error("Timed out waiting for Postgres on :#{port} after #{timeout}s") if Time.now > deadline
      sleep 0.5
    end
  end

  # Run a SELECT and return rows as an array of strings.
  # Uses -At (unaligned, tuples-only) for clean programmatic output.
  # Errors are silently discarded; callers interpret an empty result.
  def DbImages.psql_query(port, sql, database: "postgres")
    cmd = "psql -h #{HOST} -p #{port} -U postgres -At " \
          "-c #{Shellwords.shellescape(sql)} #{database} 2>/dev/null"
    `#{cmd}`.strip.split("\n").map(&:strip).reject(&:empty?)
  end

  # Execute a DDL statement via Util.run (echoes the command, exits on failure).
  def DbImages.psql_exec(port, sql, database: "postgres")
    Util.run(
      "psql -h #{HOST} -p #{port} -U postgres " \
      "-c #{Shellwords.shellescape(sql)} #{database}"
    )
  end

  # Execute a DDL statement silently; returns true on success, false otherwise.
  def DbImages.psql_exec_quiet(port, sql, database: "postgres")
    cmd = "psql -h #{HOST} -p #{port} -U postgres " \
          "-c #{Shellwords.shellescape(sql)} #{database} > /dev/null 2>&1"
    system(cmd)
  end

  # Purge registry images older than 3 days, while always retaining:
  #   (a) the current image tag (from current_image_tag)
  #   (b) the baseline anchor BASELINE_TAG
  #
  # Inject `now:` for testable age logic.  Pass `dry_run: true` to print
  # what would be purged without deleting anything.
  BASELINE_TAG    = "0.3.44"
  PURGE_AGE_DAYS  = 3

  def DbImages.purge_old(now: Time.now, dry_run: false)
    require 'json'
    require 'time'
    out = `doctl registry repository list-tags #{IMAGE_NAME} --output json 2>&1`
    unless $?.success?
      Util.exit_with_error("doctl registry list-tags failed: #{out.strip}")
    end

    entries = JSON.parse(out) || []
    if entries.empty?
      puts "purge_old: no tags found in registry — nothing to do"
      return
    end

    # Fail-safe: a purge run either knows the current latest tag (and retains
    # it) or purges nothing. Never delete when the latest is unknown — let any
    # error from current_image_tag propagate rather than swallowing it to nil.
    retained_tag = current_image_tag
    if retained_tag.nil? || retained_tag.strip.empty?
      Util.exit_with_error("purge_old: cannot determine current latest tag — refusing to purge")
    end
    cutoff = now - PURGE_AGE_DAYS * 24 * 3600

    entries.each do |entry|
      tag        = entry["tag"]
      updated_at = Time.parse(entry["updated_at"])

      # Skip untagged manifests — they have no named tag and cannot be
      # addressed by doctl registry repository delete-tag.
      if tag.nil? || tag.strip.empty?
        puts "SKIP    (untagged manifest #{entry["manifest_digest"]})"
        next
      end

      if tag == retained_tag
        puts "RETAIN  #{tag}  (current latest tag)"
        next
      end

      if tag == BASELINE_TAG
        puts "RETAIN  #{tag}  (baseline anchor)"
        next
      end

      if updated_at > cutoff
        age_days = ((now - updated_at) / 86400).round(1)
        puts "RETAIN  #{tag}  (#{age_days}d old — within #{PURGE_AGE_DAYS}-day window)"
        next
      end

      age_days = ((now - updated_at) / 86400).round(1)
      if dry_run
        puts "PURGE   #{tag}  (#{age_days}d old) [dry-run — not deleted]"
      else
        puts "PURGE   #{tag}  (#{age_days}d old)"
        Util.run(
          "doctl registry repository delete-tag #{IMAGE_NAME} " \
          "#{Shellwords.shellescape(tag)} --force"
        )
      end
    end
  end

  # List all platformdb_sess_* database names in the container on `port`.
  def DbImages.list_session_dbs(port)
    psql_query(
      port,
      "SELECT datname FROM pg_database WHERE datname LIKE '#{SESS_PREFIX}%' ORDER BY datname"
    )
  end

  # Session DB names in the container on `port` with at least one active backend.
  def DbImages.active_session_dbs(port)
    psql_query(
      port,
      "SELECT DISTINCT datname FROM pg_stat_activity WHERE datname LIKE '#{SESS_PREFIX}%'"
    ).to_set
  end

  # True when `db` exists in the container on `port`.
  def DbImages.database_exists?(port, db)
    psql_query(port, "SELECT 1 FROM pg_database WHERE datname = '#{db}'") == ["1"]
  end

  # Every running claude container paired with its port, as [name, port].
  # Containers whose port cannot be determined are skipped — there is no way to
  # talk to them and guessing a port would mean talking to somebody else's.
  def DbImages.running_containers_with_ports
    claude_containers.select { |n| container_running?(n) }.map { |n|
      port = container_port(n)
      port ? [n, port] : nil
    }.compact
  end

  # The [container, port] holding `db`, or nil when no running container has it.
  def DbImages.find_container_with_db(db)
    running_containers_with_ports.find { |(_name, port)| database_exists?(port, db) }
  end
end
