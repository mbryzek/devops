require 'open3'
require 'time'
require 'agent/paths'

# The host prerequisites a runner needs, as CODE instead of prose (ISS-531).
#
# WHY THIS EXISTS. `Depsguard::SCAN_CMD` shells out to `depsguard`, an EXTERNAL
# binary devops does not ship. It was installed on Mike's Mac, where the retired
# `depsguard-weekly` cron ran; the ISS-395 port moved the schedule onto a runner
# that was never given it. lib/depsguard.rb correctly maps "not found in PATH"
# to exit 2, the producer contract correctly records exit >1 as `check_failed`
# rather than `filed` — and that correctness is what made it silent, because a
# check that cannot run is deliberately indistinguishable in the queue from one
# with nothing to say. The weekly supply-chain scan had therefore never run on
# this fleet, once, in its entire history, with no error anywhere.
#
# `browserslist-update` came over in the same batch and had the same gap on
# `npx`. Two of the three ported producers could not run on the machine they were
# ported to.
#
# The prerequisites were not undocumented — they are a comment block in
# launchd/com.bryzek.dev-agent.plist. A comment cannot be run, so nothing ever
# compared it to a machine. This file is that list, executable.
#
# THE PATH IS RESOLVED THE WAY THE AGENT RESOLVES IT, NOT THE WAY YOUR SHELL
# DOES, and that is the whole reason the `node` gap survived being looked for.
# launchd runs `/bin/zsh -lc`: a LOGIN, NON-INTERACTIVE shell, which sources
# .zprofile and never .zshrc. nvm is loaded from .zshrc, so every node nvm
# manages is on PATH in a human's terminal and on no PATH the agent ever sees.
# A doctor that probed its own ENV["PATH"] would report `node ok` to the person
# running it by hand and be wrong about the only process that matters. So
# `agent_path` asks the login shell what the agent gets, and every probe below
# scans THAT — which also means the fix for a tool nvm provides is to install it
# somewhere the login shell can see (homebrew), not to teach launchd about nvm.
module Agent
  module Toolchain
    # One external binary and what stops working without it.
    #
    # `producers` names producer KEYS in agent/producers.yml, and is checked
    # against that file by test_dev_agent_toolchain.rb — so a producer whose
    # check shells out to a new binary cannot be added with its prerequisite left
    # off this list, and a producer renamed here cannot drift from the registry.
    # `required_by` carries the rest in prose: the uses that are jobs rather than
    # producers, which have no key to name.
    #
    # `install` is a literal command, not a description. The single question this
    # file answers on a broken machine is "what do I type", and a prose hint is
    # how the plist comment failed.
    Tool = Struct.new(:name, :required_by, :producers, :install, :required, keyword_init: true) do
      def required? = required != false
      def optional? = !required?
    end

    # Everything the dispatcher, its producers and its claimed sessions shell out
    # to. Homebrew throughout, deliberately: /opt/homebrew/bin is on the login
    # PATH that launchd hands the tick, which is exactly the property a
    # version-manager shim (nvm, rbenv, asdf) does not have.
    TOOLS = [
      Tool.new(
        name: "depsguard",
        required_by: "the weekly supply-chain config scan (`dev depsguard`, lib/depsguard.rb)",
        producers: %w[depsguard],
        install: "brew install depsguard",
      ),
      # `brew install node`, NOT nvm. nvm's node is real and installed on this
      # box; it is simply invisible to `/bin/zsh -lc`, which is the only shell
      # the agent ever runs in. See the module comment.
      Tool.new(
        name: "node",
        required_by: "`dev browserslist update`, and every JS repo a claimed session builds",
        producers: %w[browserslist-update],
        install: "brew install node",
      ),
      Tool.new(
        name: "npx",
        required_by: "`npx --yes update-browserslist-db@latest` in `dev browserslist update`",
        producers: %w[browserslist-update],
        install: "brew install node",
      ),
      Tool.new(
        name: "gh",
        required_by: "every claimed job: clone, push, open the PR, mark it ready",
        producers: [],
        install: "brew install gh && gh auth login",
      ),
      Tool.new(
        name: "git",
        required_by: "the devops self-pull every Phase A, and every job checkout",
        producers: [],
        install: "xcode-select --install",
      ),
      Tool.new(
        name: "docker",
        required_by: "`claude-db`, so every Scala suite a claimed session runs",
        producers: [],
        install: "install Docker Desktop and set it to start at login",
      ),
      Tool.new(
        name: "sbt",
        required_by: "the platform, acumen and lib-* suites",
        producers: [],
        install: "brew install sbt",
      ),
      Tool.new(
        name: "claude",
        required_by: "the claimed session itself — a runner without it claims work it cannot do",
        producers: [],
        install: "see https://claude.com/claude-code",
      ),
      # Best-effort BY DESIGN (see Agent::Notify), so its absence must not fail
      # provisioning or file an issue. It is still reported, because what it
      # costs is silent: the runner-offline push is the one alert the design
      # calls load-bearing, and a missing `openclaw` turns it into a no-op that
      # looks exactly like a healthy fleet.
      Tool.new(
        name: "openclaw",
        required_by: "push notifications (Agent::Notify) — PR ready, gave up, runner offline",
        producers: [],
        install: "install openclaw (notifications are best-effort; nothing else breaks)",
        required: false,
      ),
    ].freeze

    # Once a day, matching Agent::Maintenance. A toolchain does not change
    # between ticks, and `zsh -lc` costs a process — but a machine that has never
    # checked is due immediately, so a freshly provisioned runner reports on its
    # first tick rather than a day into pretending to work.
    CADENCE_SECONDS = 24 * 3600

    Found = Struct.new(:tool, :path, :version, keyword_init: true) do
      def present? = !path.nil?
      def missing? = path.nil?
    end

    Result = Struct.new(:at, :path, :found, keyword_init: true) do
      def missing_required = found.select { |f| f.missing? && f.tool.required? }.map(&:tool)
      def missing_optional = found.select { |f| f.missing? && f.tool.optional? }.map(&:tool)
      def ok? = missing_required.empty?

      # Producer keys that cannot run on this machine, deduped and ordered as
      # producers.yml orders them via TOOLS. This is the sentence the filed issue
      # leads with: "missing depsguard" is a fact about a laptop, "the depsguard
      # producer has never run" is the failure.
      def blocked_producers = missing_required.flat_map(&:producers).uniq
    end

    module_function

    # The PATH launchd hands `dev agent tick`, which is the PATH every producer
    # check and every claimed session inherits.
    #
    # Falls back to this process's own PATH if the login shell cannot be asked —
    # a wrong-but-close answer beats reporting every tool missing, and under
    # launchd the two are the same string anyway (the tick IS already inside that
    # shell), so the fallback only ever affects a human running this by hand on a
    # box with a broken profile.
    def agent_path(env: ENV)
      out, status = Open3.capture2("/bin/zsh", "-lc", "printf %s \"$PATH\"")
      return env["PATH"].to_s if !status.success? || out.strip.empty?
      out.strip
    rescue Errno::ENOENT
      env["PATH"].to_s
    end

    # `command -v` against an explicit PATH rather than the caller's. Ruby has no
    # such thing, and shelling out to `command -v` would resolve in the CALLER's
    # shell — the exact mistake this module exists to stop making.
    def which(binary, path:)
      path.to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?
        candidate = File.join(File.expand_path(dir), binary)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    # Best-effort `--version`, purely for the operator's report. Never used to
    # decide present/absent: a tool that resolves but refuses `--version` is
    # installed, and treating it as missing would file an issue about a working
    # machine.
    def version(path)
      out, status = Open3.capture2e(path, "--version")
      return nil unless status.success?
      out.lines.first.to_s.strip[0, 60]
    rescue StandardError
      nil
    end

    def check(tools: TOOLS, now: Time.now, path: nil, versions: true)
      resolved = path || agent_path
      found = tools.map do |tool|
        binary = which(tool.name, path: resolved)
        Found.new(tool: tool, path: binary, version: binary && versions ? version(binary) : nil)
      end
      Result.new(at: now, path: resolved, found: found)
    end

    # ---- cadence (runner-local, same shape as Agent::Maintenance) ----
    #
    # A marker file rather than a platform call, for the reason ISS-520 gives at
    # length: this is a fact about ONE machine, and arbitrating it fleet-wide
    # would leave N-1 machines unchecked.

    def state = Agent::Paths.read_json(Agent::Paths.toolchain_file)

    def last_check_at(record = state)
      at = record && record["at"]
      at && (Time.parse(at) rescue nil)
    end

    def due?(now: Time.now)
      last = last_check_at
      last.nil? || (now - last) >= CADENCE_SECONDS
    end

    def record(result)
      Agent::Paths.write_json(
        Agent::Paths.toolchain_file,
        {
          "at" => result.at.utc.iso8601,
          "missing" => result.missing_required.map(&:name),
          "missing_optional" => result.missing_optional.map(&:name),
        },
        mode: 0600,
      )
    end

    # ---- what a human, or an issue, is told ----

    # Stable regardless of TOOLS' order, because it is half a dedup key: the
    # server does not re-file while a non-terminal issue with the same
    # fingerprint exists, and an order-dependent key would file a second issue
    # for the same machine the day someone reorders the list above.
    def missing_key(result) = result.missing_required.map(&:name).sort.join("+")

    def issue_fingerprint(result, hostname) = "toolchain:#{hostname}:#{missing_key(result)}"

    def issue_title(result, hostname)
      "dev-agent: #{hostname} is missing #{result.missing_required.map(&:name).sort.join(', ')}"
    end

    # The body is written to be actionable without an ssh session: what is
    # missing, what it stops, what to type, and why nothing showed up as an
    # error. That last part is the point of the issue — anyone reading the queue
    # sees a quiet producer, and the whole finding is that quiet and healthy look
    # identical from there.
    def issue_body(result, hostname)
      lines = ["`#{hostname}` is missing #{result.missing_required.length} required tool(s).", ""]
      result.missing_required.each do |tool|
        lines << "- **#{tool.name}** — needed by #{tool.required_by}"
        lines << "  - install: `#{tool.install}`"
        lines << "  - blocks producer(s): #{tool.producers.map { |k| "`#{k}`" }.join(', ')}" unless tool.producers.empty?
      end
      unless result.blocked_producers.empty?
        lines += ["", "Until this is fixed, these producers record `check_failed` on this machine and file " \
                      "nothing: #{result.blocked_producers.map { |k| "`#{k}`" }.join(', ')}. A check that " \
                      "exits >1 is deliberately indistinguishable from a clean one in the queue, so the " \
                      "absence of issues from them is not evidence they are passing (ISS-531)."]
      end
      unless result.missing_optional.empty?
        lines += ["", "Also absent, not required: #{result.missing_optional.map { |t| "`#{t.name}`" }.join(', ')}."]
      end
      lines += ["", "Resolution is the agent's own PATH (`/bin/zsh -lc`), NOT an interactive shell's — a tool " \
                    "that only a version manager loaded from `.zshrc` provides (nvm, rbenv, asdf) is present " \
                    "in your terminal and invisible to every process launchd starts. Install into homebrew.",
                "", "Verify with `dev agent doctor` on that machine.",
                "", "PATH checked:", "", "```",
                result.path.to_s.split(File::PATH_SEPARATOR).reject(&:empty?).uniq.join("\n"), "```"]
      lines.join("\n")
    end
  end
end
