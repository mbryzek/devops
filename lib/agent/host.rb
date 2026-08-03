require 'json'
require 'open3'
require 'agent/paths'

# Machine identity and self-registration (design §4.5).
#
# Provisioning a new mini is: install the toolchain, `dev auth ai`, drop the
# plist. The first tick registers the machine, and the server derives
# max_concurrency from the reported hardware — so heterogeneous machines need no
# configuration.
#
# IDENTITY IS KEYED ON IOPlatformUUID, NOT ON THE CACHE FILE. The UUID survives
# OS reinstalls, disk wipes and Time Machine restores and is unique per machine,
# so registration is an upsert: losing agent.identity gets the existing row and a
# fresh token back rather than creating a ghost runner that goes stale, fires the
# invariant, and has to be retired by hand. hostname cannot serve as the key
# (DHCP, renames, collisions) — it is a display label only.
module Agent
  module Host
    Identity = Struct.new(:runner_id, :token, keyword_init: true)

    module_function

    def capture(cmd)
      out, status = Open3.capture2(*cmd)
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end

    def hardware_uuid
      out = capture(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
      out&.[](/"IOPlatformUUID"\s*=\s*"([^"]+)"/, 1)
    end

    def sysctl(key)
      capture(["sysctl", "-n", key])
    end

    def tool_versions
      {
        "claude" => capture(["claude", "--version"]),
        "sbt"    => capture(["sbt", "--script-version"]),
        "docker" => capture(["docker", "--version"]),
        "gh"     => capture(["gh", "--version"])&.lines&.first&.strip,
        "ruby"   => RUBY_VERSION,
        "node"   => capture(["node", "--version"]),
      }.compact
    end

    def registration_payload
      uuid = hardware_uuid or
        raise "Could not read IOPlatformUUID (ioreg -rd1 -c IOPlatformExpertDevice). This must be a Mac."
      {
        hardware_uuid: uuid,
        hostname: capture(["hostname"]) || "unknown",
        model: sysctl("hw.model"),
        arch: capture(["uname", "-m"]),
        memory_bytes: sysctl("hw.memsize")&.to_i,
        cpu_cores: sysctl("hw.ncpu")&.to_i,
        cpu_brand: sysctl("machdep.cpu.brand_string"),
        os_version: capture(["sw_vers", "-productVersion"]),
        tool_versions: tool_versions,
      }.compact
    end

    def cached_identity
      data = Agent::Paths.read_json(Agent::Paths.identity_file)
      return nil unless data && data["runner_id"] && data["token"]
      Identity.new(runner_id: data["runner_id"], token: data["token"])
    end

    def cache_identity(runner_id, token)
      Agent::Paths.write_json(Agent::Paths.identity_file,
                              { "runner_id" => runner_id, "token" => token }, mode: 0600)
      Identity.new(runner_id: runner_id, token: token)
    end

    # The cached identity, registering if there is none. Returns
    # [Identity, runner_hash_or_nil] — the runner hash is present only on the
    # registering path, which is also the only path that learns max_concurrency
    # and `paused` without a second call.
    def identity(use_localhost:, force_register: false)
      cached = force_register ? nil : cached_identity
      return [cached, nil] if cached

      res = Agent::Api.register_runner(registration_payload, use_localhost: use_localhost)
      runner = res.fetch("runner")
      [cache_identity(runner.fetch("id"), res.fetch("token")), runner]
    end
  end
end
