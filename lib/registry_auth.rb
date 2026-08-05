require 'fileutils'
require 'json'
require 'tmpdir'

# Authenticating this process to the DigitalOcean container registry WITHOUT
# going through Docker's credential store.
#
# ── Why this exists (ISS-578) ────────────────────────────────────────────────
#
# `doctl registry login` writes the minted credential into whatever credential
# helper ~/.docker/config.json names, and `docker pull`/`docker push` read it
# back out the same way. On this runner that helper is `desktop`
# (docker-credential-desktop, shipped inside Docker.app), and from a headless
# session it BLOCKS FOREVER in an open(2) at startup — measured on 2026-08-05,
# reproducible on demand, and blocking BOTH directions:
#
#     docker-credential-desktop version         -> never returns
#     doctl registry login                      -> never returns
#     docker pull registry.digitalocean.com/... -> never returns
#
# It does not fail. It hangs, holding the session open with no output, which is
# why the ISS-569 run lost every DB-backed spec: `claude-db start` sat in the
# login for 25+ minutes and the session had nothing to react to. Two concurrent
# sessions were wedged on the same step at the same moment, so this is a
# property of the machine, not of one session's environment.
#
# Bounding the login with a timeout is necessary but NOT sufficient — the pull
# immediately after it hangs on the same helper for the same reason, so a
# timeout alone converts one silent hang into two loud failures and still leaves
# no session able to get a database.
#
# ── What we do instead ───────────────────────────────────────────────────────
#
# `doctl registry docker-config` emits a complete Docker config with the
# credential embedded as a plain `auths.<registry>.auth` entry and NO
# `credsStore` key. Point this process at a private config directory holding
# that, and no credential helper is ever invoked — not `desktop`, not
# `osxkeychain`. The whole failure class (wedged helper, locked keychain under
# launchd, no GUI session) stops being reachable.
#
# That directory SHADOWS the real one rather than replacing it: every entry of
# ~/.docker except config.json is symlinked in. This matters — `contexts/` is
# how docker finds the Docker Desktop daemon (`currentContext: desktop-linux`)
# and `buildx/` is where db-image's multi-arch builder lives. A bare directory
# with only a config.json in it silently changes which daemon and which builder
# every subsequent docker command uses.
#
# Scope is DOCKER_CONFIG in this process's environment rather than a `--config`
# flag per call site, because two of the callers (release-docker-k8s, release-db)
# reach the registry through a build script we do not own and cannot pass a flag
# to. An inherited environment variable reaches them; a flag does not.
module RegistryAuth
  # Where the credential lands, and how long it lives. Long enough for a
  # multi-arch buildx push of a real image, short enough that a leaked copy is
  # worthless by the time anyone finds it. Never `--never-expire`: that mints a
  # permanent token that accumulates in the DO token list.
  EXPIRY_SECONDS = 4 * 60 * 60

  # Minting is one API call to DigitalOcean. Anything past this is a dead
  # network or a wedged doctl, never work in progress.
  MINT_TIMEOUT_SECONDS = 90

  # Set on the environment so a CHILD devops process (claude-db shelling out to
  # db-image, release-db shelling out to db-image) reuses what the parent
  # already minted instead of minting again per process.
  SCOPE_ENV = "DEVOPS_REGISTRY_AUTH_SCOPE"

  # The real Docker config directory, remembered because DOCKER_CONFIG itself
  # now points at our shadow. Without this a child would shadow the shadow, and
  # inherit symlinks into a temp directory its parent deletes on exit.
  SOURCE_ENV = "DEVOPS_REGISTRY_AUTH_SOURCE"

  # Authenticate this process (and everything it spawns) to the registry.
  #
  # `read_write: false` mints pull-only credentials, which is all claude-db and
  # any other consumer needs. Push callers pass true. Returns the config dir.
  def RegistryAuth.authenticate!(read_write:)
    wanted = read_write ? "rw" : "ro"
    return ENV["DOCKER_CONFIG"] if RegistryAuth.satisfied_by_environment?(wanted)

    Util.assert_installed("doctl", "https://docs.digitalocean.com/reference/doctl/how-to/install/")

    source = RegistryAuth.source_config_dir
    config_json, outcome = RegistryAuth.mint(read_write: read_write)
    RegistryAuth.abort_on_mint_failure(outcome) if outcome != :ok

    dir = RegistryAuth.build_shadow_dir(source, config_json)
    ENV["DOCKER_CONFIG"] = dir
    ENV[SCOPE_ENV] = wanted
    ENV[SOURCE_ENV] = source
    dir
  end

  # A parent already minted, and what it minted covers what we need. Push scope
  # covers pull; the reverse is not true, so a claude-db self-heal that shells
  # out to `db-image --push` correctly mints its own.
  def RegistryAuth.satisfied_by_environment?(wanted)
    have = ENV[SCOPE_ENV]
    dir = ENV["DOCKER_CONFIG"]
    return false if have.nil? || dir.nil?
    return false unless File.exist?(File.join(dir, "config.json"))
    have == "rw" || have == wanted
  end

  # The Docker config directory to shadow — the real one, even when we have
  # already replaced DOCKER_CONFIG with a shadow of it.
  def RegistryAuth.source_config_dir
    ENV[SOURCE_ENV] || ENV["DOCKER_CONFIG"] || File.expand_path("~/.docker")
  end

  # Ask doctl for a credential-helper-free Docker config, as a parsed Hash.
  # Returns [hash_or_nil, :ok | :failed | :timed_out].
  #
  # The output IS a DigitalOcean API token, so it is captured rather than
  # streamed: Util.run would echo it to the console in verbose mode and append
  # it to the release log in quiet mode, and a release log is not a secret store.
  def RegistryAuth.mint(read_write:)
    cmd = ["doctl", "registry", "docker-config", "--expiry-seconds", EXPIRY_SECONDS.to_s]
    cmd << "--read-write" if read_write
    stdout, outcome = Util.run_with_timeout(cmd, :timeout_seconds => MINT_TIMEOUT_SECONDS, :capture => true)
    return [nil, outcome] if outcome != :ok

    parsed = JSON.parse(stdout.to_s)
    return [nil, :failed] if parsed["auths"].to_h.empty?
    [parsed, :ok]
  rescue JSON::ParserError
    [nil, :failed]
  end

  def RegistryAuth.abort_on_mint_failure(outcome)
    detail =
      if outcome == :timed_out
        "`doctl registry docker-config` did not return within #{MINT_TIMEOUT_SECONDS}s and was killed."
      else
        "`doctl registry docker-config` failed or returned no credentials."
      end

    Util.exit_with_error(
      "Could not mint DigitalOcean container registry credentials.\n\n" \
      "  #{detail}\n\n" \
      "This is almost always doctl's own DigitalOcean auth, not Docker. Check it:\n\n" \
      "    doctl account get\n\n" \
      "and if that fails or is expired, re-authenticate:\n\n" \
      "    doctl auth init\n\n" \
      "Note that we deliberately do NOT use `doctl registry login` or Docker's\n" \
      "credential store here — see lib/registry_auth.rb (ISS-578). If you are\n" \
      "debugging this, do not \"fix\" it by adding the login back."
    )
  end

  # A private directory that behaves like the real Docker config directory in
  # every respect except credentials. Removed when the process exits, so the
  # minted token does not outlive the command that needed it.
  def RegistryAuth.build_shadow_dir(source, config_json)
    dir = Dir.mktmpdir("devops-docker-config")
    File.chmod(0700, dir)
    at_exit { FileUtils.remove_entry(dir) if File.exist?(dir) }

    RegistryAuth.link_source_entries(source, dir)
    File.open(File.join(dir, "config.json"), File::WRONLY | File::CREAT | File::TRUNC, 0600) do |f|
      f.write(JSON.pretty_generate(RegistryAuth.merged_config(source, config_json)))
    end
    dir
  end

  # Symlink everything the real config dir holds EXCEPT config.json: contexts,
  # buildx state, cli-plugins, daemon.json. Symlinks (not copies) so state
  # buildx writes during a push lands in the real directory and is still there
  # for the next run.
  def RegistryAuth.link_source_entries(source, dir)
    return unless File.directory?(source)
    Dir.children(source).each do |name|
      next if name == "config.json"
      File.symlink(File.join(source, name), File.join(dir, name))
    end
  end

  # The real config's settings with its credentials swapped out for ours.
  #
  # `currentContext` has to survive — dropping it silently moves every docker
  # command in the process from the Docker Desktop daemon to the default socket.
  # `credsStore`/`credHelpers` must NOT survive: they are the entire bug.
  def RegistryAuth.merged_config(source, config_json)
    path = File.join(source, "config.json")
    real = File.exist?(path) ? (JSON.parse(File.read(path)) rescue {}) : {}
    real.reject { |k, _| ["credsStore", "credHelpers", "auths"].include?(k) }
        .merge("auths" => config_json.fetch("auths"))
  end
end
