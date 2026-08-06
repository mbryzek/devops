require 'json'
require 'agent/paths'
require 'agent/toolchain'
require 'util'

# `browse` — the visual-inspection CLI — made reachable from the agent's PATH,
# and made to say so when it cannot run (ISS-658).
#
# WHY THIS EXISTS. CLAUDE.md's "Visual Inspection" section tells every session to
# run `browse <url>`, screenshot a running app and look at it. The tool is real
# and it works: it lives in the `claude` repo at tools/browse/browse.mjs with its
# node_modules committed beside it. Nothing ever put it on a PATH. That gap is
# invisible interactively — Mike's login PATH happens to reach it — and on a
# runner `browse` is `command not found`, so an autonomous session working a
# frontend issue has no way to render the page it just changed.
#
# It is not a niche gap: six of the seven UI repos are frontends. ISS-656 shipped
# a change to a public sign form's error display on structural evidence alone —
# an SSR assertion that the native-validation attributes were gone plus an AST
# scan of every .svelte file — which proves the attributes went away and never
# shows the styled error appearing where the browser's bubble used to be.
#
# THE SHIM LIVES IN devops, NOT IN claude/bin, and that is a decision rather than
# a convenience. devops/bin is already on the login PATH the tick hands every
# session (it is how `dev`, `api` and `claude-db` resolve), `dev agent tick`
# pulls this repo every Phase A, and an autonomous session may not write outside
# plans/ in the claude repo at all. So a shim added here reaches the whole fleet
# without anyone touching a machine. It is the arrangement `api` already has, and
# it carries the same single prerequisite, recorded in Agent::Toolchain::TOOLS:
# devops/bin must be on the LOGIN PATH.
#
# WHAT A RUNNER STILL NEEDS IS GOOGLE CHROME, NOT PLAYWRIGHT'S CHROMIUM, and
# getting that backwards would have made this check worse than none. browse.mjs
# launches `channel: "chrome"` — the system Chrome — because this network's
# egress gateway rejects the Playwright CDN with an HTTP 400, so
# `npx playwright install` cannot fetch a bundled browser here at all. A
# preflight written against the bundled chromium would call a working machine
# broken: on the runner this was written on, `chromium.executablePath()` names a
# revision that is not on disk while `browse https://example.com` returns a
# screenshot. So the probe launches exactly what browse launches, through the
# same BROWSE_CHANNEL override, and closes it again — the only check that cannot
# disagree with the tool it is checking.
module BrowseTool

  # One prerequisite, whether it holds, and the literal command that satisfies
  # it. `fix` is a command for the same reason Agent::Toolchain::Tool#install is:
  # the one question a broken runner asks is "what do I type", and a prose hint
  # is how the plist comment failed.
  Requirement = Struct.new(:name, :ok, :detail, :fix, keyword_init: true) do
    def ok? = ok == true
  end

  # Launching Chrome headless and closing it costs well under a second on a
  # healthy box, and fails immediately on one with no Chrome. The ceiling is here
  # for the third case: a Chrome that starts and wedges. `dev agent tick` runs
  # this probe once a day while holding the work lock, so an unbounded check
  # would stall the runner's entire queue behind a hung browser.
  PROBE_TIMEOUT_SECONDS = 60

  # Mirrors browse.mjs. The probe must launch the browser browse will launch, not
  # the one it defaults to, or an operator who set this would get a green check
  # for a channel that is never used.
  DEFAULT_CHANNEL = "chrome".freeze

  module_function

  def channel = ENV["BROWSE_CHANNEL"].to_s.empty? ? DEFAULT_CHANNEL : ENV["BROWSE_CHANNEL"]

  def tool_dir = File.join(Agent::Paths.claude_repo, "tools", "browse")

  def entrypoint = File.join(tool_dir, "browse.mjs")

  def playwright_module = File.join(tool_dir, "node_modules", "playwright")

  # ---- the prerequisites ------------------------------------------------------

  # The browser probe runs ONLY when everything it depends on is already
  # satisfied. Probing without node, or without the playwright package, reports
  # "chrome is missing" on a machine whose actual problem is a missing checkout —
  # the wrong sentence sends whoever is fixing the box to the wrong place, which
  # is the failure the non-executable-file case in Agent::Toolchain warns about.
  def requirements(browser: true)
    base = [checkout_requirement, playwright_requirement, node_requirement]
    return base unless browser && base.all?(&:ok?)
    base + [browser_requirement]
  end

  def checkout_requirement
    Requirement.new(
      name: "browse.mjs",
      ok: File.file?(entrypoint),
      detail: File.file?(entrypoint) ? entrypoint : "not at #{entrypoint}",
      fix: "gh repo clone mbryzek/claude #{Agent::Paths.claude_repo}",
    )
  end

  def playwright_requirement
    present = Dir.exist?(playwright_module)
    Requirement.new(
      name: "playwright",
      ok: present,
      detail: present ? playwright_module : "not at #{playwright_module}",
      fix: "npm install --prefix #{tool_dir}",
    )
  end

  # Resolved against the CALLER's PATH, deliberately unlike Agent::Toolchain,
  # which resolves against the agent's login PATH. This runs inside the shim, so
  # the caller's PATH is the one the `exec` below will actually use. `node` has
  # its own entry in TOOLS, and that entry is where the login-PATH question is
  # asked.
  def node_requirement
    found = Agent::Toolchain.which("node", path: ENV["PATH"].to_s)
    Requirement.new(
      name: "node",
      ok: !found.nil?,
      detail: found || "not on PATH",
      fix: "brew install node",
    )
  end

  def browser_requirement
    out, outcome = Util.run_with_timeout(
      ["node", "-e", probe_script],
      timeout_seconds: PROBE_TIMEOUT_SECONDS, capture: true, quiet: true
    )
    # The FIRST line, unlike the last-line contract this module's own `--check`
    # honours upwards: the probe below emits one line by construction, so the
    # only way there is a second is node getting in first with a stack trace —
    # and then the headline is what says what happened, not the frame it
    # happened in.
    detail = case outcome
             when :ok then "launched and closed headless #{channel}"
             when :timed_out then "#{channel} did not answer within #{PROBE_TIMEOUT_SECONDS}s"
             else out.to_s.lines.map(&:strip).reject(&:empty?).first || "#{channel} would not launch"
             end
    Requirement.new(
      name: "browser",
      ok: outcome == :ok,
      detail: detail,
      fix: "brew install --cask google-chrome",
    )
  end

  # Every failure prints ONE line to STDOUT and exits non-zero.
  #
  # stdout, not stderr, because `Util.run_with_timeout(capture:)` diverts stdout
  # only — a probe that reported on stderr would hand back a bare exit code and
  # the check would have nothing to say. The `require` is wrapped for the same
  # reason: an uncaught module error goes to stderr as a stack trace, which would
  # vanish and leave "would not launch" standing in for a real answer. And it is
  # required by ABSOLUTE PATH so the probe does not depend on whichever cwd it
  # happens to be spawned in.
  def probe_script
    <<~JS
      const fail = (e) => {
        console.log(String((e && e.message) || e).split("\\n")[0]);
        process.exit(1);
      };
      let pw;
      try {
        pw = require(#{JSON.generate(playwright_module)});
      } catch (e) {
        fail(e);
      }
      pw.chromium
        .launch({ headless: true, channel: process.env.BROWSE_CHANNEL || #{JSON.generate(DEFAULT_CHANNEL)} })
        .then((b) => b.close())
        .then(() => process.exit(0))
        .catch(fail);
    JS
  end

  # ---- what the operator, and Agent::Toolchain, are told ----------------------

  # THE LAST NON-EMPTY LINE IS THE CONTRACT. `Agent::Toolchain` runs this as
  # `browse --check` and reports that line as the reason the tool is unusable, so
  # the one-line summary goes last and everything else goes above it.
  def report(io: $stdout)
    checks = requirements
    width = checks.map { |c| c.name.length }.max
    checks.each do |c|
      io.puts "  #{c.ok? ? 'ok  ' : 'FAIL'} #{c.name.ljust(width)}  #{c.detail}"
      io.puts "       #{' ' * width}  fix: #{c.fix}" unless c.ok?
    end
    failed = checks.reject(&:ok?)
    return 0 if failed.empty?
    io.puts
    io.puts summary(failed)
    1
  end

  def summary(failed)
    "browse cannot run: #{failed.map { |c| "#{c.name} — #{c.detail}" }.join('; ')}"
  end

  # The message a session sees when it reaches for visual inspection on a machine
  # that cannot provide it. It says so in one place rather than letting a node
  # stack trace stand in for an answer — a session that reads "Cannot find module
  # 'playwright'" is one that will go and try to install playwright.
  def unavailable_message(failed)
    lines = [summary(failed), ""]
    failed.each { |c| lines << "  #{c.name}: #{c.detail}" << "    fix: #{c.fix}" }
    lines << ""
    lines << "Visual inspection is unavailable on this machine until that is fixed. A session " \
             "should SAY the UI change was never looked at rather than imply otherwise (ISS-658); " \
             "`dev agent doctor` reports this too."
    lines.join("\n")
  end

  # ---- entry point ------------------------------------------------------------

  # `exec`, not a subprocess: browse's own stdout, stderr and exit code reach the
  # caller untouched rather than through a wrapper that would have to reproduce
  # all three, and every flag browse.mjs grows arrives without this file being
  # edited. Never returns.
  def exec_browse(argv) = exec("node", entrypoint, *argv)

  # Returns an exit status, except on the happy path, where it hands off and
  # never returns at all.
  def main(argv, io: $stdout, err: $stderr)
    if argv.first == "--check"
      return usage_error(err, "browse --check takes no other arguments") if argv.length > 1
      return report(io: io)
    end

    # Answered here rather than passed through, because `Agent::Toolchain#version`
    # calls `--version` on every tool it resolves. Handing that to browse.mjs —
    # which has no such flag — would run a full preflight, launch Chrome, and
    # then fail anyway, so the doctor would start a browser twice per run to
    # learn nothing. What is useful in that slot is which tool this shim reaches.
    if argv.first == "--version"
      io.puts "browse shim → #{entrypoint}"
      return 0
    end

    # `--help` (and a bare `browse`) reach browse.mjs's own usage text. That still
    # needs the playwright package — browse.mjs imports it at the top level — and
    # never launches a browser, so gating usage on Chrome would hide the one
    # message that explains the flags.
    help = argv.empty? || argv.any? { |a| %w[--help -h help].include?(a) }
    failed = requirements(browser: !help).reject(&:ok?)
    unless failed.empty?
      err.puts unavailable_message(failed)
      return 1
    end

    exec_browse(argv)
  end

  def usage_error(err, message)
    err.puts message
    err.puts "usage: browse <url> [options] | browse --check"
    2
  end
end
