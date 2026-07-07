require 'pathname'
require 'json'
require 'tempfile'

module Util
    # Sync <app>-config + <app>-secrets from the git-crypt env repo to the
    # cluster via bin/k8s-secrets (which requires env/apps/<app>/env files).
    # Aborts the caller on failure (Util.run semantics) — never release
    # against stale config/secrets. nil namespace uses k8s-secrets' default.
    def Util.sync_k8s_secrets(app, namespace: nil)
      cmd = File.join(File.dirname(__FILE__), "../bin/k8s-secrets") + " --app #{app}"
      cmd += " --namespace #{namespace}" if namespace
      Util.run(cmd)
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

    def Util.run(cmd, params={})
      quiet = (params.has_key?(:quiet) && params[:quiet]) ? true  : false
      ignore_error = (params.has_key?(:ignore_error) && params[:ignore_error]) ? true : false
      if !quiet
          puts "==> #{cmd}"
      end
      if !system(cmd)
        if !ignore_error
          Util.exit_with_error("Command failed: #{cmd}")
        end
      end
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
