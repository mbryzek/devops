require 'pathname'
require 'json'
require 'tempfile'
require 'fileutils'

module Util
    # Quiet release mode. When enabled, Util.run appends subprocess output to
    # a log file instead of streaming it, Util.detail messages go to the log,
    # and Util.step prints one concise "label... done (12s)" line per stage.
    # State lives in ENV so child scripts spawned by a release (k8s-build,
    # k8s-secrets, k8s-deploy) inherit it automatically; the same scripts run
    # standalone stay fully verbose.
    QUIET_ENV = "DEVOPS_QUIET"
    LOG_FILE_ENV = "DEVOPS_LOG_FILE"

    def Util.quiet!(log_file)
      FileUtils.mkdir_p(File.dirname(log_file))
      File.write(log_file, "")
      ENV[QUIET_ENV] = "1"
      ENV[LOG_FILE_ENV] = log_file
    end

    def Util.quiet?
      ENV[QUIET_ENV] == "1" && !ENV[LOG_FILE_ENV].to_s.empty?
    end

    def Util.log_file
      ENV[LOG_FILE_ENV]
    end

    # Append a message to the quiet-mode log. No-op when not in quiet mode.
    def Util.log(msg)
      return if !Util.quiet?
      File.open(Util.log_file, 'a') { |f| f.puts msg }
    end

    # Progress detail: printed in verbose mode, logged in quiet mode.
    def Util.detail(msg)
      if Util.quiet?
        Util.log(msg)
      else
        puts msg
      end
    end

    # Raised by Util.step_failed!: a stage that failed but must not abort the
    # release. Util.step renders it as "label... failed (3s)" and swallows it.
    class StepFailed < StandardError; end

    # Mark the enclosing Util.step as failed without aborting the caller. For
    # best-effort stages (the post-deploy changelog and reconcile hooks), whose
    # failure is explicitly ignored but must not be reported as "done".
    def Util.step_failed!
      raise StepFailed
    end

    # A named stage of a release. Quiet mode: "label... done (12s)" on one
    # line. Verbose mode: the traditional underlined section header. Returns
    # the block's value.
    #
    # The two halves are written separately and flushed, which is deliberate:
    # `dev deploy` reads this stream from the subprocess pipe and treats the
    # dangling "label... " as "this stage is running now" (DeployProgress).
    # Print the whole line at once and the parent can only ever narrate stages
    # that are already over.
    #
    # The completion half is printed from an ensure block so a stage that
    # raises — Util.run aborts with exit_with_error, which is a SystemExit —
    # still closes its line, as "failed (8s)". Otherwise a failed release left
    # a dangling partial line that both the log and the parent read as a stage
    # still in progress.
    def Util.step(label)
      if Util.quiet?
        print "#{label}... "
        $stdout.flush
        started = Time.now
        ok = false
        begin
          result = yield
          ok = true
          result
        rescue StepFailed
          nil
        ensure
          puts "#{ok ? 'done' : 'failed'} (#{(Time.now - started).round}s)"
          $stdout.flush
        end
      else
        puts ""
        puts Util.underline(label)
        begin
          yield
        rescue StepFailed
          puts "#{label}: FAILED (ignored)"
          nil
        end
      end
    end
    # Sync <app>-config + <app>-secrets from the git-crypt env repo to the
    # cluster via bin/k8s-secrets (which requires env/apps/<app>/env files).
    # Aborts the caller on failure (Util.run semantics) — never release
    # against stale config/secrets. nil namespace uses k8s-secrets' default.
    def Util.sync_k8s_secrets(app, namespace: nil)
      cmd = File.join(File.dirname(__FILE__), "../bin/k8s-secrets") + " --app #{app}"
      cmd += " --namespace #{namespace}" if namespace
      Util.run(cmd, passthrough: true)
    end

    # Sync a Secret/ConfigMap from a manifest file so the live object ends up
    # with EXACTLY the given desired_keys — no more, no less — without ever
    # deleting the object (no outage window).
    #
    # `kubectl apply` alone is not enough: its client-side 3-way merge only
    # removes a key if it saw that key drop out of the object's
    # `last-applied-configuration` annotation history. A key that entered the
    # object any other way (a `kubectl edit`/`patch`, or the object having
    # existed before this script ever applied it) is invisible to that diff
    # and survives every future sync forever, even after being deleted from
    # the source env file. (Incident: workers-secrets carried a stray
    # HEADLESS=true added via `kubectl edit` that `k8s-secrets` re-synced
    # through untouched for weeks — 2026-07-06.)
    #
    # So: apply first (adds/updates desired keys, zero downtime), then
    # explicitly diff the live object's keys against desired_keys and
    # null-patch away anything extra. Nulling a key in a JSON merge patch
    # deletes it; a targeted patch never removes/recreates the object itself.
    def Util.sync_k8s_resource(kind, name, file, desired_keys, namespace:)
      Util.run("kubectl apply -f #{file}")

      existing_json = `kubectl get #{kind} #{name} -n #{namespace} -o json 2>/dev/null`
      return if existing_json.strip.empty?

      existing_keys = (JSON.parse(existing_json)["data"] || {}).keys
      stale_keys = existing_keys - desired_keys
      return if stale_keys.empty?

      Util.warning("Removing stale key(s) from #{kind}/#{name} not present in source: #{stale_keys.join(', ')}")
      patch = { "data" => stale_keys.each_with_object({}) { |k, h| h[k] = nil } }
      Tempfile.create(["k8s-prune-#{name}-", ".json"]) do |f|
        f.write(JSON.generate(patch))
        f.flush
        Util.run("kubectl patch #{kind} #{name} -n #{namespace} --type=merge --patch-file=#{f.path}")
      end
    end

    # Ensure Docker is authenticated to the DigitalOcean container registry
    # before a push. `doctl registry login` mints a fresh credential (30-day
    # default) and writes it to Docker's credential store, so a stale/expired
    # token can never surface as a `401 Unauthorized` mid-release. We run it
    # unconditionally before every push: it's idempotent, fast, and — without
    # --never-expire — produces an ephemeral OAuth credential that is NOT a
    # never-expiring token and does NOT accumulate in the DO token list.
    # Requires doctl itself to be authenticated (`doctl auth init`); if that
    # parent token has expired the login fails loudly here rather than leaving
    # `docker push` to fail with an opaque 401.
    def Util.registry_login
      Util.assert_installed("doctl", "https://docs.digitalocean.com/reference/doctl/how-to/install/")
      Util.run("doctl registry login")
    end

    # params:
    #   :quiet        - do not echo the command line
    #   :ignore_error - do not abort when the command fails
    #   :passthrough  - the command is a devops script that manages its own
    #                   quiet-mode output (and may prompt the user); never
    #                   redirect its output to the log
    #
    # Returns whether the command succeeded, which is only ever interesting
    # alongside :ignore_error — every other path aborts on failure.
    def Util.run(cmd, params={})
      quiet = (params.has_key?(:quiet) && params[:quiet]) ? true  : false
      ignore_error = (params.has_key?(:ignore_error) && params[:ignore_error]) ? true : false
      passthrough = (params.has_key?(:passthrough) && params[:passthrough]) ? true : false

      if Util.quiet? && !passthrough
        Util.log("==> #{cmd}")
        ok = system("(#{cmd}) >> '#{Util.log_file}' 2>&1")
        if !ok && !ignore_error
          $stderr.puts ""
          $stderr.puts "Command failed: #{cmd}"
          $stderr.puts ""
          $stderr.puts "Last 40 lines of #{Util.log_file}:"
          $stderr.puts `tail -40 '#{Util.log_file}'`
          Util.exit_with_error("Command failed (full log: #{Util.log_file})")
        end
        return ok
      end

      if !quiet && !(Util.quiet? && passthrough)
          # stderr, not stdout: stdout is a data channel for several devops
          # scripts (bin/env emits shell that the caller evals, bin/db emits a
          # URL), and a "==> ..." line mixed into it corrupts the consumer.
          $stderr.puts "==> #{cmd}"
      end
      ok = system(cmd) ? true : false
      if !ok && !ignore_error
        Util.exit_with_error("Command failed: #{cmd}")
      end
      ok
    end

    def Util.exit_with_error(msg)
        $stderr.puts ""
        $stderr.puts "ERROR: #{msg}"
        $stderr.puts ""
        exit 1
    end

    def Util.indent(text, size = 2)
      indent = ' ' * size
      text.split("\n").map { |line| indent + line }.join("\n")
    end

    def Util.underline(text)
        "#{text}\n#{'=' * text.length}"
    end

    # Clickable terminal hyperlink (OSC 8): the text renders normally and opens
    # the url on click in terminals that support it. Returns the bare text when
    # stdout is not a terminal, so piped output and release logs stay free of
    # escape sequences.
    def Util.hyperlink(text, url)
      return text unless $stdout.tty?
      "\e]8;;#{url}\e\\#{text}\e]8;;\e\\"
    end

    # Decode subprocess bytes as UTF-8, replacing anything invalid.
    #
    # Every pipe read hands back ASCII-8BIT, and a chunked read can split a
    # multi-byte character across two chunks. Two things then go wrong unless
    # the bytes are decoded deliberately: a regex match on the raw string can
    # blow up on a malformed byte, and writing it to a text-mode IO transcodes
    # (Encoding::UndefinedConversionError). Hold subprocess output as binary,
    # and run it through here at the edges where it becomes text.
    def Util.to_utf8(str)
      str.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def Util.installed?(cmd)
      system("which #{cmd} > /dev/null 2>&1") ? true : false
    end

    def Util.cleanpath(path)
        Pathname.new(path).cleanpath
    end

    def Util.warning(text)
        $stderr.puts ""
        $stderr.puts ('*') * 100
        $stderr.puts Util.indent("WARNING: " + text)
        $stderr.puts ('*') * 100
    end

    # Produce `path` such that a concurrent reader never sees it half-written.
    # Yields a scratch path for the block to fill, then renames it over the target
    # — rename(2) is atomic within a filesystem, so a reader gets either the whole
    # old file or the whole new one, never an empty or truncated one. A plain
    # `cmd > path` redirect truncates the target the instant the command starts,
    # which is how parallel `dev deploy` releases used to read a 0-byte config and
    # die with JSON::ParserError. The scratch name carries the pid so two processes
    # writing the same target never share it.
    def Util.write_atomically(path)
      tmp = "#{path}.tmp.#{Process.pid}"
      begin
        yield tmp
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    end

    def Util.read_file(path)
      full_path = File.expand_path(path)
      if !File.exist?(full_path)
        Util.exit_with_error("Cannot find file #{full_path}")
      end
      IO.read(full_path).strip
    end

    def Util.assert_installed(cmd, url=nil)
      if !system("which %s > /dev/null" % cmd)
        msg = "Please install %s" % cmd
        if url
          msg += " (%s)" % url
        end
        Util.exit_with_error(msg)
      end
    end
    
    def Util.assert_sem_installed
      Util.assert_installed("sem-info", "https://github.com/mbryzek/schema-evolution-manager")
    end
end
