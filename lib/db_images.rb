require 'shellwords'
require 'time'

# Registry, Docker and Postgres mechanics for the session-DB image workflow.
#
# Everything here is APP-AGNOSTIC. Which database, which container, which image
# — that is DbApp's job (lib/db_apps.rb), derived from the devops config. What
# is left in here is the machinery every app shares: talking to Docker, talking
# to Postgres on a given port, and naming a session.
#
# ONE CONTAINER PER SCHEMA TAG. There is no single container and no fixed port:
# the container is "<database>-claude-<schema-tag>" and its host port is
# allocated per container (see lib/db_ports.rb). Every helper that talks to
# Postgres therefore takes the port of the container it is addressing.
#
# Why: a single shared container on a single port meant that adopting a new
# image forced `docker rm -f` on it, which destroyed EVERY session's database
# rather than just the caller's (measured: one `claude-db start` wiped four
# other sessions' databases).
module DbImages
  REGISTRY = "registry.digitalocean.com/bryzek"

  HOST = "localhost"

  # Postgres identifier limit — what session database names are truncated to.
  MAX_IDENTIFIER_LENGTH = 63

  # Docker image tag for a schema tag: the schema tag itself, unmodified.
  # The image ref is "registry.digitalocean.com/bryzek/<database>:<schema-tag>".
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

  # Session ID reduced to something legal in a Postgres identifier. The app's
  # prefix and the length limit are applied by DbApp#session_db_name, which is
  # the only caller — the prefix length varies per app.
  #
  # Sanitisation rules:
  #   - lowercase
  #   - non-alphanumeric characters → underscore
  #   - collapse consecutive underscores
  #   - strip leading / trailing underscores
  def DbImages.sanitize_session_id(sid)
    sid.downcase
       .gsub(/[^a-z0-9]/, '_')
       .gsub(/_+/, '_')
       .sub(/^_+/, '')
       .sub(/_+$/, '')
  end

  # A repository that has never been pushed to does not exist in the registry at
  # all, and doctl reports that as a 404 rather than an empty list. For an app
  # whose first image has not been built yet that is "no tags", not a failure —
  # the whole point of verify-db-images is to notice and heal exactly that.
  #
  # Matched on the message because doctl exits 1 for every error alike; the
  # alternative is treating a network outage as an empty registry, which is the
  # mistake this deliberately avoids.
  def DbImages.repository_missing?(doctl_output)
    doctl_output =~ /repository not found/i ? true : false
  end

  # True if the given schema tag has a pushed image in `app`'s registry repo.
  #
  # Requires doctl to be authenticated.  Exits with an error on unexpected
  # doctl failures (e.g. network error) so callers are never silently misled
  # into thinking a tag is absent when it might just be unreachable.
  def DbImages.registry_tag_exists?(app, tag)
    require 'json'
    out = `doctl registry repository list-tags #{app.image_name} --output json 2>&1`
    unless $?.success?
      return false if DbImages.repository_missing?(out)
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

  # Container naming, and the list of an app's containers, live on DbApp — they
  # are derived from the database name.

  # True when the named container exists at all (running or stopped).
  def DbImages.container_exists?(name)
    system("docker inspect #{Shellwords.shellescape(name)} > /dev/null 2>&1")
  end

  # True when the named container is up and running.
  def DbImages.container_running?(name)
    out = `docker inspect #{Shellwords.shellescape(name)} --format='{{.State.Running}}' 2>/dev/null`.strip
    out == "true"
  end

  # Seconds since the named container was created, or nil when that cannot be
  # read. nil means "age unknown", and every caller must treat that as "too young
  # to touch" — the same keep-on-doubt rule as DbApp#session_db_ages.
  def DbImages.container_age_seconds(name)
    out = `docker inspect #{Shellwords.shellescape(name)} --format='{{.Created}}' 2>/dev/null`.strip
    return nil if out.empty?
    (Time.now - Time.parse(out)).to_i
  rescue ArgumentError
    nil
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

  # Purge `app`'s registry images older than 3 days, while always retaining:
  #   (a) the app's current schema tag
  #   (b) the app's baseline anchor (docker/baseline-tag), because every later
  #       image is built by replaying scripts on top of it
  #
  # Inject `now:` for testable age logic.  Pass `dry_run: true` to print
  # what would be purged without deleting anything.
  #
  # Per-tag decisions go through Util.detail, not puts: release-db runs this
  # inside a Util.step, and a stage owns its line of stdout for the length of
  # its block — one stray puts splices itself into that line and the stage never
  # reads as finished. Standalone (`db-image purge`, verify-db-images) nothing
  # is in quiet mode, so detail still prints exactly as before.
  PURGE_AGE_DAYS = 3

  def DbImages.purge_old(app, now: Time.now, dry_run: false)
    require 'json'
    require 'time'
    out = `doctl registry repository list-tags #{app.image_name} --output json 2>&1`
    unless $?.success?
      if DbImages.repository_missing?(out)
        Util.detail("purge_old: #{app.image_name} has no registry repository yet — nothing to do")
        return
      end
      Util.exit_with_error("doctl registry list-tags failed: #{out.strip}")
    end

    entries = JSON.parse(out) || []
    if entries.empty?
      Util.detail("purge_old: no tags found in #{app.image_name} — nothing to do")
      return
    end

    # Fail-safe: a purge run either knows the current latest tag (and retains
    # it) or purges nothing. Never delete when the latest is unknown — let any
    # error from current_schema_tag propagate rather than swallowing it to nil.
    retained_tag = DbImages.image_tag(app.current_schema_tag)
    if retained_tag.nil? || retained_tag.strip.empty?
      Util.exit_with_error("purge_old: cannot determine current latest tag — refusing to purge")
    end
    baseline_tag = app.baseline_tag
    cutoff = now - PURGE_AGE_DAYS * 24 * 3600

    entries.each do |entry|
      tag        = entry["tag"]
      updated_at = Time.parse(entry["updated_at"])

      # Skip untagged manifests — they have no named tag and cannot be
      # addressed by doctl registry repository delete-tag.
      if tag.nil? || tag.strip.empty?
        Util.detail("SKIP    (untagged manifest #{entry["manifest_digest"]})")
        next
      end

      if tag == retained_tag
        Util.detail("RETAIN  #{tag}  (current latest tag)")
        next
      end

      if tag == baseline_tag
        Util.detail("RETAIN  #{tag}  (baseline anchor)")
        next
      end

      if updated_at > cutoff
        age_days = ((now - updated_at) / 86400).round(1)
        Util.detail("RETAIN  #{tag}  (#{age_days}d old — within #{PURGE_AGE_DAYS}-day window)")
        next
      end

      age_days = ((now - updated_at) / 86400).round(1)
      if dry_run
        Util.detail("PURGE   #{tag}  (#{age_days}d old) [dry-run — not deleted]")
      else
        Util.detail("PURGE   #{tag}  (#{age_days}d old)")
        Util.run(
          "doctl registry repository delete-tag #{app.image_name} " \
          "#{Shellwords.shellescape(tag)} --force"
        )
      end
    end
  end

  # True when `db` exists in the container on `port`.
  def DbImages.database_exists?(port, db)
    psql_query(port, "SELECT 1 FROM pg_database WHERE datname = '#{db}'") == ["1"]
  end
end
