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

    # Mark the enclosing Util.step as failed without aborting the caller: for a
    # stage whose failure is explicitly ignored but must not be reported as
    # "done".
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
    # before a push. Every caller here pushes, so this asks for push scope; the
    # pull-only caller (claude-db) asks RegistryAuth for read-only directly.
    #
    # This used to be `doctl registry login`, which writes the credential into
    # Docker's credential store — and on a machine whose store is the Docker
    # Desktop helper, that call HANGS FOREVER rather than failing (ISS-578). See
    # lib/registry_auth.rb for what replaced it and why.
    def Util.registry_login
      RegistryAuth.authenticate!(read_write: true)
    end

    # Run `cmd` (an argv ARRAY, never a shell string) under a hard deadline.
    # Returns [stdout_or_nil, :ok | :failed | :timed_out].
    #
    # Two things here are load-bearing, both learned from ISS-578:
    #
    #   1. THE CHILD GETS ITS OWN PROCESS GROUP, and the deadline kills the
    #      GROUP. The hang that motivated this was `doctl` blocked on a wedged
    #      `docker-credential-desktop` child; killing just the pid we spawned
    #      leaves that grandchild alive holding the same lock, so the retry
    #      hangs identically. `pgroup: true` + `kill(-pid)` reaps the whole tree.
    #
    #   2. stdin is /dev/null. A subprocess that decides to prompt must fail,
    #      not block: nobody is at the keyboard in a Claude session or a cron
    #      release, and "waiting for input that will never come" is
    #      indistinguishable from "working" until someone notices hours later.
    #
    # `capture: true` returns stdout instead of streaming it, which is how a
    # command whose OUTPUT is a credential stays out of the console and out of
    # the quiet-mode log. Streaming output goes to the log in quiet mode, exactly
    # like Util.run.
    #
    # `capture` protects the OUTPUT, not the command. The argv is echoed, same as
    # Util.run — so never put a secret in an argument; pass it by file or by
    # environment.
    def Util.run_with_timeout(cmd, timeout_seconds:, capture: false, quiet: false)
      raise ArgumentError, "cmd must be an array, got #{cmd.class}" unless cmd.is_a?(Array)

      printable = cmd.join(" ")
      if Util.quiet?
        Util.log("==> #{printable}")
      elsif !quiet
        $stderr.puts "==> #{printable}"
      end

      out_read, out_write = capture ? IO.pipe : [nil, nil]

      # `capture` diverts stdout ONLY. stderr keeps going wherever it would have
      # anyway — the log in quiet mode, the console otherwise. The reason to
      # capture at all is that stdout carries a credential; throwing the
      # subprocess's own diagnostics away with it would leave a failure with
      # nothing to read.
      redirect = {}
      if capture
        redirect[:out] = out_write
        redirect[:err] = [Util.log_file, "a"] if Util.quiet?
      elsif Util.quiet?
        redirect[[:out, :err]] = [Util.log_file, "a"]
      end

      pid = Process.spawn(*cmd, **redirect, :in => File::NULL, :pgroup => true)
      out_write&.close
      # Drain the pipe concurrently: a child that outgrows the pipe buffer blocks
      # on write, and waiting for exit before reading would deadlock on it.
      drain = capture ? Thread.new { out_read.read } : nil

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      status = nil
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Util.kill_process_group(pid)
          drain&.kill
          out_read&.close
          return [nil, :timed_out]
        end
        sleep 0.2
      end

      stdout = drain&.value
      out_read&.close
      [stdout, status.success? ? :ok : :failed]
    end

    # Kill a process group started with `pgroup: true`, politely then not.
    def Util.kill_process_group(pid)
      Process.kill("TERM", -pid)
      # A wedged process may not be in a state to handle TERM at all, so do not
      # wait long before escalating.
      20.times do
        return if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.1
      end
      Process.kill("KILL", -pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
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
        # stdin is /dev/null, for the same reason run_with_timeout does it: this
        # branch has already sent the child's stdout AND stderr to a log file, so
        # a child that decides to prompt asks its question where nobody can see
        # it and then blocks on a terminal read that will never be answered.
        # That is not a slow release, it is a permanent one — `api publish` held
        # `dev deploy` on "Publishing apibuilder specs..." for 23 minutes on
        # 2026-08-07 and only ended in a Ctrl-C. EOF makes such a child fail
        # instead, which is a failure someone can read.
        ok = system("(#{cmd}) >> '#{Util.log_file}' 2>&1 < /dev/null")
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

    # A span of seconds, compactly: 45s / 2m31s / 1h04m / 3d04h.
    #
    # Each tier drops the unit below it once that unit stops carrying information -- nobody
    # reads the seconds off a three-day span. Was DeployProgress's, which is where it grew
    # its first three tiers; `dev queries` renders sample spans with it too, and a span there
    # is routinely days, which is what the fourth tier is for.
    def Util.duration(seconds)
      s = seconds.round
      return "#{s}s" if s < 60

      m, s = s.divmod(60)
      return format("%dm%02ds", m, s) if m < 60

      h, m = m.divmod(60)
      return format("%dh%02dm", h, m) if h < 24

      d, h = h.divmod(24)
      format("%dd%02dh", d, h)
    end
end
