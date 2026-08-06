require 'agent/paths'

# The visual-inspection path, made reachable from a runner (ISS-608).
#
# WHY THIS EXISTS. CLAUDE.md's "Visual Inspection" section tells every session to
# `use the browse tool to visually inspect running web applications`, and for
# frontend work that is not decoration — a chart-layout issue's entire deliverable
# is how something looks. On the runners `browse` was `command not found`, so a
# session had exactly two options: ship a layout change it never saw, or spend its
# budget rebuilding a screenshot harness by hand. Both happened, on consecutive
# nights, on ISS-600 and ISS-601.
#
# THE TOOL WAS NEVER MISSING. It ships in the `claude` repo at
# tools/browse/browse.mjs and works on these machines today. What was missing is
# the one thing nobody had written down: something that puts it on the PATH the
# agent actually has. `~/code/claude/bin` is on that PATH and is what the claude
# repo's README tells you to add, but browse.mjs lives in `tools/`, not `bin/`, so
# nothing there ever resolved it.
#
# SO DEVOPS SHIPS IT, the same way devops ships `api`. `~/code/devops/bin` is
# already on the login PATH by construction — the tick runs out of that checkout
# and fast-forwards it every Phase A — so a wrapper here reaches every runner with
# no per-machine provisioning step to forget. A symlink into /opt/homebrew/bin
# would have been one more manual step on one more machine, which is the shape of
# the bug, not the fix.
#
# WHAT THIS REFUSES TO DO IS GUESS. Each of the three prerequisites fails with the
# literal command that fixes it, because the failure this replaces was a
# playwright stack trace about a missing dylib — twenty minutes of a session's
# budget to reach "install Chrome".
module Browse

  # Where the implementation lives inside the claude checkout. Resolved through
  # Agent::Paths.claude_repo rather than hardcoded so the DEV_AGENT_CLAUDE_REPO
  # seam the push guard already uses works here too, which is what lets this be
  # tested against a throwaway directory instead of the developer's home.
  IMPL_RELATIVE = File.join("tools", "browse", "browse.mjs").freeze

  # The browser browse actually drives, at the exact path Playwright resolves
  # `channel: "chrome"` to on darwin (playwright-core lib/server/registry). Probing
  # anything else would let the doctor report a healthy machine that browse still
  # cannot launch on.
  CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".freeze

  # PLAYWRIGHT'S OWN CHROMIUM IS NOT AN OPTION ON THIS FLEET, and this constant
  # exists so the next person to reach for it stops here instead of finding out
  # the slow way. The egress gateway rejects the Playwright CDN: a fetch of
  # cdn.playwright.dev redirects to playwright.download.prss.microsoft.com and
  # comes back **HTTP 400**, so `npx playwright install chromium` cannot download
  # a browser here at all.
  #
  # Worse, it does not say so. A half-extracted browser leaves the version
  # directory in place, the installer treats an existing directory as satisfied
  # and exits 0, and the launch then dies with SIGABRT and a `dlopen` error about
  # a missing `Chromium Framework` dylib. That is what ISS-608 hit, and why its
  # own suggested remedy ("rm -rf the cache and reinstall") could never have
  # worked. browse.mjs already resolved this by driving the system Chrome; this
  # note is here so the toolchain does not un-resolve it.
  PLAYWRIGHT_CDN_BLOCKED = "the egress gateway returns HTTP 400 for cdn.playwright.dev".freeze

  # browse.mjs reads BROWSE_CHANNEL to drive a build other than stable Chrome.
  # Honoured here so the guard can never refuse a run that would have worked: a
  # machine deliberately pointed at another channel has no reason to own Chrome,
  # and browse.mjs reports its own error for a channel it cannot launch.
  CHANNEL_ENV = "BROWSE_CHANNEL".freeze

  # A test seam in exactly the sense Agent::Paths' DEV_AGENT_* overrides are —
  # so the :no_chrome branch can be exercised on a machine that has Chrome
  # installed, which every machine this matters on does. Nothing in production
  # sets it.
  CHROME_ENV = "DEV_BROWSE_CHROME".freeze

  module_function

  def impl_path = File.join(Agent::Paths.claude_repo, IMPL_RELATIVE)

  def chrome_path(env: ENV) = env[CHROME_ENV].to_s.empty? ? CHROME : env[CHROME_ENV]

  # Whether the default Chrome channel is the one that will be launched. Any
  # other value is somebody else's browser to have installed.
  def chrome_channel?(env: ENV)
    channel = env[CHANNEL_ENV].to_s
    channel.empty? || channel == "chrome"
  end

  # nil when the run may proceed, otherwise the symbol naming what is absent.
  # Same shape as SessionDb.blocking_reason, and for the same reason: the caller
  # is a bin/ script that should hold no policy.
  #
  # Order matters. A machine with no claude checkout has nothing to run and
  # nothing to run it with, so naming Chrome first would send whoever is fixing it
  # to install a browser for a tool that is not there.
  def blocking_reason(path: nil, env: ENV)
    return :no_impl unless File.file?(impl_path)
    return :no_node if which("node", path: path || env["PATH"]).nil?
    return :no_chrome if chrome_channel?(env: env) && !File.executable?(chrome_path(env: env))
    nil
  end

  # `command -v` against an explicit PATH, matching Agent::Toolchain.which.
  #
  # Unlike the doctor's copy this one defaults to the CALLER's PATH, and that is
  # correct rather than an oversight: the doctor predicts what a DIFFERENT process
  # will resolve and so must ask the login shell, whereas this runs in the very
  # shell that is about to `exec node` a few lines later. Asking anything else
  # here would answer a question nobody asked.
  def which(binary, path: nil)
    (path || ENV["PATH"]).to_s.split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?
      candidate = File.join(File.expand_path(dir), binary)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  # A literal command per failure, never a description. The single question a
  # session asks here is "what do I type".
  def message(reason:)
    case reason
    when :no_impl
      "browse: no visual-inspection tool at #{impl_path}\n" \
        "  browse ships in the claude repo; this machine has no checkout of it.\n" \
        "  fix: gh repo clone mbryzek/claude ~/code/claude"
    when :no_node
      "browse: `node` is not on this shell's PATH\n" \
        "  browse is a node script, so nothing here can run without it.\n" \
        "  fix: brew install node   (NOT nvm — launchd's `/bin/zsh -lc` never reads .zshrc)"
    when :no_chrome
      "browse: Google Chrome is not installed at #{chrome_path}\n" \
        "  browse drives the system Chrome, not Playwright's bundled Chromium:\n" \
        "  #{PLAYWRIGHT_CDN_BLOCKED}, so `npx playwright install` cannot fetch one here.\n" \
        "  fix: brew install --cask google-chrome"
    else
      "browse: cannot run (#{reason})"
    end
  end
end
