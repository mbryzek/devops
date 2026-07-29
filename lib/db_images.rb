require 'shellwords'

# Registry + container constants and helpers for the platformdb Docker workflow.
#
# Used by bin/claude-db (per-session DB lifecycle) and any other tooling that
# needs to know where images live or how to talk to the local container.
module DbImages
  REGISTRY      = "registry.digitalocean.com/bryzek"
  IMAGE_NAME    = "platformdb"
  CONTAINER     = "platformdb-claude"
  HOST          = "localhost"
  PORT          = 5433
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

  # Docker image tag for a schema tag: "<schema-tag>-r<recipe-hash>".
  #
  # The image is schema PLUS recipe (seed rows, init script, Dockerfile), so a
  # recipe-only change has to produce a different image tag — otherwise the
  # registry and every local Docker cache keep serving the old image under the
  # unchanged schema tag and the change reaches nobody until the next schema
  # release. platform-postgresql's docker/image-tag.sh is the single definition
  # of that tag; shelling out to it keeps this from drifting into a second one.
  def DbImages.image_tag(schema_tag, dir: PLATFORM_POSTGRESQL_DIR)
    script = File.join(dir, "docker", "image-tag.sh")
    unless File.executable?(script)
      Util.exit_with_error(
        "Image tag script not found or not executable: #{script}\n" \
        "Update the platform-postgresql checkout at #{dir} (this devops " \
        "version requires docker/image-tag.sh)."
      )
    end
    out = `#{Shellwords.shellescape(script)} #{Shellwords.shellescape(schema_tag)} 2>&1`.strip
    unless $?.success? && !out.empty?
      Util.exit_with_error("Could not compute image tag for #{schema_tag}: #{out}")
    end
    out
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

  # True when the platformdb-claude container is up and running.
  def DbImages.container_running?
    out = `docker inspect #{CONTAINER} --format='{{.State.Running}}' 2>/dev/null`.strip
    out == "true"
  end

  # Image the running container was started from (e.g. "registry.…/platformdb:0.3.44").
  def DbImages.container_image
    `docker inspect #{CONTAINER} --format='{{.Config.Image}}' 2>/dev/null`.strip
  end

  # Block until the container's Postgres accepts connections, or raise an error.
  def DbImages.wait_for_postgres(timeout: 30)
    deadline = Time.now + timeout
    loop do
      system("pg_isready -h #{HOST} -p #{PORT} -q > /dev/null 2>&1")
      return if $?.success?
      Util.exit_with_error("Timed out waiting for Postgres on :#{PORT} after #{timeout}s") if Time.now > deadline
      sleep 0.5
    end
  end

  # Run a SELECT and return rows as an array of strings.
  # Uses -At (unaligned, tuples-only) for clean programmatic output.
  # Errors are silently discarded; callers interpret an empty result.
  def DbImages.psql_query(sql, database: "postgres")
    cmd = "psql -h #{HOST} -p #{PORT} -U postgres -At " \
          "-c #{Shellwords.shellescape(sql)} #{database} 2>/dev/null"
    `#{cmd}`.strip.split("\n").map(&:strip).reject(&:empty?)
  end

  # Execute a DDL statement via Util.run (echoes the command, exits on failure).
  def DbImages.psql_exec(sql, database: "postgres")
    Util.run(
      "psql -h #{HOST} -p #{PORT} -U postgres " \
      "-c #{Shellwords.shellescape(sql)} #{database}"
    )
  end

  # Execute a DDL statement silently; returns true on success, false otherwise.
  def DbImages.psql_exec_quiet(sql, database: "postgres")
    cmd = "psql -h #{HOST} -p #{PORT} -U postgres " \
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

  # List all platformdb_sess_* database names.
  def DbImages.list_session_dbs
    psql_query(
      "SELECT datname FROM pg_database WHERE datname LIKE '#{SESS_PREFIX}%' ORDER BY datname"
    )
  end

  # Return the set of session DB names that have at least one active backend.
  def DbImages.active_session_dbs
    psql_query(
      "SELECT DISTINCT datname FROM pg_stat_activity WHERE datname LIKE '#{SESS_PREFIX}%'"
    ).to_set
  end
end
