require 'etc'
require 'shellwords'
require 'socket'

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
  def DbImages.current_tag
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

  # Session identifier used to name the per-session database.
  #
  # Prefers CLAUDE_SESSION_ID (set automatically by Claude Code) which
  # guarantees distinct names across parallel sessions.  Falls back to a
  # stable per-user-per-machine string for manual invocations where
  # parallel isolation is not required.
  def DbImages.session_id
    sid = ENV['CLAUDE_SESSION_ID']
    return sid if sid && !sid.strip.empty?
    user = Etc.getlogin rescue "user"
    host = Socket.gethostname.split('.').first rescue "local"
    "#{user}_#{host}"
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

  # Purge registry images older than 10 days, while always retaining:
  #   (a) the current latest tag (from current_tag)
  #   (b) the baseline anchor BASELINE_TAG
  #
  # Inject `now:` for testable age logic.  Pass `dry_run: true` to print
  # what would be purged without deleting anything.
  BASELINE_TAG    = "0.3.44"
  PURGE_AGE_DAYS  = 10

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
    # error from current_tag propagate rather than swallowing it to nil.
    retained_tag = current_tag
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
