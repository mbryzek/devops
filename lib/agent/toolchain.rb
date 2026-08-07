require 'time'
require 'agent/paths'
require 'agent/shell'

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
    # `producers` names producer KEYS in the platform registry, and is checked
    # against that file by test_dev_agent_toolchain.rb — so a producer whose
    # check shells out to a new binary cannot be added with its prerequisite left
    # off this list, and a producer renamed here cannot drift from the registry.
    # `required_by` carries the rest in prose: the uses that are jobs rather than
    # producers, which have no key to name.
    #
    # `install` is a literal command, not a description. The single question this
    # file answers on a broken machine is "what do I type", and a prose hint is
    # how the plist comment failed.
    # `paths` is for the one prerequisite shape a PATH scan cannot see: a macOS
    # .app bundle (ISS-608). When it is set those absolute candidates are probed
    # and PATH is not consulted at all — Google Chrome is a real prerequisite of
    # `browse` and has never been on anybody's PATH, so a list that could only
    # express "binary on PATH" would have had to leave it off and report a
    # healthy machine that cannot render a page.
    #
    # `unsupported` is the third state, and it is here because PRESENT AND WRONG
    # is a thing this list could not say (ISS-781). Everything above answers "is
    # it installed"; node 26 is installed, runs, answers `--version`, and
    # deadlocks Playwright's browser installer forever. A doctor that can only
    # report presence reports `node ok` on a machine where no frontend session can
    # obtain a browser — the same shape of silence as the rest of this file, one
    # level in. It takes the probed version string and returns the reason it
    # cannot be used, or nil.
    Tool = Struct.new(:name, :required_by, :producers, :install, :required, :paths, :unsupported,
                      keyword_init: true) do
      def required? = required != false
      def optional? = !required?

      # Probed at a fixed location rather than resolved on PATH. The doctor and
      # the issue body both branch on this, because "not on the agent's PATH" is
      # the wrong sentence to hand someone whose Chrome is simply not installed.
      def absolute? = !Array(paths).empty?

      # Nil whenever we cannot tell, which includes the whole `versions: false`
      # path. Guessing here would file an issue about a working machine, and the
      # rest of this file is emphatic that a tool refusing `--version` is still
      # installed.
      def unsupported_reason(version_string)
        return nil if unsupported.nil? || version_string.nil?
        unsupported.call(version_string)
      end
    end

    # Major version out of whatever `--version` printed: `v26.6.0` and `26.6.0`
    # both give 26. Nil rather than 0 when there is no number to read, so an
    # unrecognised format is "cannot tell" and not "version zero, condemn it".
    def self.major(version_string)
      version_string.to_s[/(\d+)\./, 1]&.to_i
    end

    # WHY NODE 26 IS REFUSED (ISS-781), measured on a runner on 2026-08-07.
    #
    # `playwright install` downloads a browser fine and then deadlocks unpacking
    # it — no crash, no error, no exit, 0% CPU, indefinitely. Two sessions before
    # this one lost about an hour each to waiting it out, and the workaround they
    # left behind (curl the zip, `unzip` it into the version directory by hand,
    # touch INSTALLATION_COMPLETE and DEPENDENCIES_VALIDATED) is a cost every
    # frontend session was going to keep paying.
    #
    # It is a Node regression, not a Playwright bug and not this fleet. Same
    # archive, same machine, same minute: v22.14.0, v24.9.0 and v25.9.0 all
    # extract it; v26.6.0 and v26.7.0 both wedge at the identical byte. The
    # deadlock is a lost pipe wakeup between yauzl's fd-slicer Readable and
    # zlib's InflateRaw Writable — the source ends up paused with 40564 bytes
    # buffered while the sink sits empty with `needDrain=false`, so no `drain` is
    # ever emitted and nothing resumes the source. It bites the first zip entry
    # whose compressed size exceeds one read chunk, which makes it perfectly
    # deterministic and is why "it always stops on the same file" looked like a
    # corrupt archive. It is not: `unzip` of the identical bytes takes 5 seconds.
    #
    # SCOPE, stated narrowly on purpose. Node 26 runs everything else here,
    # including Playwright ITSELF — with browsers already on disk, playbook-www's
    # suite is 34 passed on 26.6.0. Only the installer's extract step hangs. The
    # message says so, because a reason that overclaims is one an operator
    # correctly ignores.
    #
    # WHY IT IS REQUIRED RATHER THAN A WARNING. A runner in this state cannot run
    # any frontend e2e suite it does not already have browsers for, and reports
    # nothing — ISS-779 shipped two playbook-www PRs with the suite unrun on
    # exactly that machine (ISS-780).
    NODE_EXTRACT_DEADLOCK = lambda do |version_string|
      major = Agent::Toolchain.major(version_string)
      next nil if major.nil? || major < 26
      "node #{version_string.to_s.strip} deadlocks `playwright install` while unpacking a browser " \
        "(ISS-781): the download succeeds, extraction wedges forever at 0% CPU on the first zip " \
        "entry larger than one read chunk. A Node >=26 regression in stream pipe wakeup, not a " \
        "Playwright bug — 22, 24 and 25 all extract the same archive. Node 26 is otherwise fine " \
        "here, including RUNNING Playwright once browsers are on disk; it is only the installer " \
        "that hangs. Node 24 is the current Active LTS"
    end

    # The one command that puts a usable node on a runner, written once because
    # TWO tools below need it (`node` and `npx` come out of the same formula) and
    # a fleet-wide command that exists in two copies is one a fix lands on half of.
    #
    # PINNED TO 24, and the pin is the whole fix for ISS-781: plain
    # `brew install node` is what put a Current release on this fleet, and
    # Current is 26, which deadlocks `playwright install`. 24 is the Active LTS
    # ("Krypton"). See NODE_EXTRACT_DEADLOCK above for the measurements.
    #
    # `brew uninstall node` is part of the literal command rather than an
    # afterthought: node@24 is keg-only, so it only reaches the login PATH via
    # `brew link --force`, and leaving the unversioned `node` formula installed
    # alongside means the next `brew upgrade` relinks 26 over the top and the
    # hang comes back with nothing to show why.
    #
    # HOMEBREW_NO_AUTOREMOVE=1 IS LOAD-BEARING AND IS NOT TIDINESS (ISS-852).
    # `brew uninstall` runs an autoremove pass afterwards, and that pass does not
    # stop at the tree it just orphaned: it sweeps EVERY formula whose install
    # receipt says `installed_as_dependency` and which nothing depends on any
    # more. Running this line on a Mac on 2026-08-07 swept 8 formulae, and
    # `tailscale` was one of them — brew removed the /opt/homebrew/bin symlinks
    # and INSTALL_RECEIPT.json, and only root-owned binaries inside the keg
    # stopped it removing the keg too. Nothing looked broken until the CLI was
    # invoked, because the already-running `tailscaled` still held its own path.
    # Which formulae get swept depends entirely on receipt flags, so it is a
    # different tool on every machine and it is silent on all of them. Orphaned
    # node deps left behind are harmless and a later deliberate `brew autoremove`
    # collects them; silently unlinking a VPN client is not.
    # THE OPT LINK IS PUT BACK BY HAND, AND IT IS NOT TIDINESS EITHER (ISS-897).
    #
    # `--ignore-dependencies` above is what lets the uninstall run at all, and it
    # does precisely what it says: other formulae DO depend on `node`
    # (`brew uses --installed node` answers `mongosh` on a Mac here), and brew
    # removes the keg and leaves them in place believing they still have a node.
    # They do not. A formula built against `node` is shebanged at the ABSOLUTE
    # opt path,
    #
    #   $ head -1 .../mongosh/2.8.3/libexec/.../bin/mongosh.js
    #   #!/opt/homebrew/opt/node/bin/node
    #
    # and `brew uninstall node` deletes <prefix>/opt/node along with the keg. So
    # running this line on a Mac on 2026-08-07 left every mongosh invocation
    # answering `bad interpreter: /opt/homebrew/opt/node/bin/node: no such file
    # or directory`, and `dev agent doctor` called that machine all-green,
    # because mongosh is not one of the tools it checks. Which formulae break is
    # whatever `brew uses --installed node` returns on that box, so it is a
    # different tool on every machine and silent on all of them — the same shape
    # as ISS-852 directly above, one dependency edge further out.
    #
    # It points at the opt NAME `node@24`, not at a Cellar path, so brew's own
    # <prefix>/opt/node@24 stays the single place the keg version is written down
    # and this link survives every node@24 patch bump untouched.
    #
    # It only ever FILLS A HOLE. `[ -e ]` follows the symlink, so an absent
    # opt/node and a dangling one both qualify while a live one — an uninstall
    # that failed, or a `node` formula somebody wants — is left exactly alone;
    # repointing that would leave brew's own view of an installed formula lying.
    # And brew's `Keg#optlink` unlinks whatever is there before relinking, so if
    # the `node` formula is ever installed again this disappears, which is right.
    #
    # REINSTALLING THE DEPENDENTS was the other way to fix it and is worse:
    # `brew reinstall mongosh` pulls the `node` formula back in as a dependency,
    # `node` is Current, and Current is the release NODE_EXTRACT_DEADLOCK exists
    # to keep off this fleet. The remediation would reintroduce what it remediates.
    NODE_OPT_RELINK =
      '[ -e "$(brew --prefix)/opt/node" ] || ln -sfn node@24 "$(brew --prefix)/opt/node"'

    NODE_INSTALL =
      "brew install node@24 && HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --ignore-dependencies node " \
      "; brew link --overwrite --force node@24 ; #{NODE_OPT_RELINK}"

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
      # Homebrew, NOT nvm. nvm's node is real and installed on this box; it is
      # simply invisible to `/bin/zsh -lc`, which is the only shell the agent ever
      # runs in. See the module comment.
      #
      # The install command is NODE_INSTALL above, where the pin to 24 and the
      # autoremove suppression are explained.
      Tool.new(
        name: "node",
        required_by: "`dev browserslist update`, and every JS repo a claimed session builds",
        producers: %w[browserslist-update],
        install: NODE_INSTALL,
        unsupported: NODE_EXTRACT_DEADLOCK,
      ),
      # No `unsupported:` here even though npx ships with node, and that is
      # deliberate rather than an omission: `npx --version` prints NPM's version
      # (11.x today), so NODE_EXTRACT_DEADLOCK would be reading the wrong number
      # off it — silently nil now, and a false positive the day npm reaches 26.
      # The node entry above is where this is judged.
      Tool.new(
        name: "npx",
        required_by: "`npx --yes update-browserslist-db@latest` in `dev browserslist update`",
        producers: %w[browserslist-update],
        install: NODE_INSTALL,
      ),
      # The one tool here devops SHIPS rather than installs: `api` sits in
      # `bin/` next to `dev` itself. It is on this list anyway because the plist
      # runs `~/code/devops/bin/dev` by ABSOLUTE PATH, so `dev` starts fine on a
      # box whose login PATH never mentions that directory — and then
      # `run_step(["api"], ...)` inside the codegen sweep ENOENTs, which comes
      # back as `api failed in .` for every backend and "skipped" for every
      # frontend that depends on one. That is not hypothetical: it is what the
      # retired `codegen-sync-weekly` openclaw cron hit on 2026-07-08, and the
      # prompt of that cron is where the requirement was written down (ISS-396
      # deleted the cron, so this line is where the knowledge lives now).
      #
      # `producers: []` deliberately, even though the `codegen-sync` producer is
      # what suffers. That producer has no check — it files unconditionally and
      # the claimed SESSION runs the sweep — so naming it would make the issue
      # body say it "records check_failed and files nothing", which is the one
      # thing that does not happen here.
      Tool.new(
        name: "api",
        required_by: "the apibuilder/DAO regen `dev codegen sync` runs in every clone " \
                     "(bin/dev, `run_step([\"api\"], ...)`) — i.e. all of the `codegen-sync` " \
                     "session's work, plus any claimed session that reruns codegen",
        producers: [],
        install: "ships in devops/bin — put it on the LOGIN PATH: " \
                 "echo 'export PATH=\"$HOME/code/devops/bin:$PATH\"' >> ~/.zprofile",
      ),
      # The visual-inspection path, and the second tool devops SHIPS rather than
      # installs (ISS-608). Same reasoning as `api` directly above: the launcher
      # sits in bin/ beside `dev`, so the only way to be missing it is to have a
      # login PATH that never mentions that directory.
      #
      # What made this one silent is worth stating, because it is not the shape
      # the rest of this list has. Nothing ERRORED. CLAUDE.md tells every session
      # to `use the browse tool to visually inspect running web applications`;
      # `browse` was `command not found`; and a session that cannot render a page
      # does not fail, it ships a layout change it never looked at. Two nights
      # running, ISS-600 and ISS-601 — both issues whose entire deliverable was
      # how something looks — hand-rolled a screenshot harness instead, and this
      # doctor reported "all required tools present" on that machine both times.
      Tool.new(
        name: "browse",
        required_by: "the visual inspection CLAUDE.md prescribes for every UI change — " \
                     "`browse <url>` (bin/browse, lib/browse.rb). Without it a session " \
                     "verifies a layout change it never saw, and nothing reports an error",
        producers: [],
        install: "ships in devops/bin — put it on the LOGIN PATH: " \
                 "echo 'export PATH=\"$HOME/code/devops/bin:$PATH\"' >> ~/.zprofile",
      ),
      # The browser `browse` actually drives, and the first entry here that is not
      # on PATH — see `Tool#absolute?`. The path is the one Playwright resolves
      # `channel: "chrome"` to on darwin, copied from playwright-core's registry
      # rather than guessed, so this cannot pass while browse still fails.
      #
      # NOT Playwright's bundled Chromium — but for a narrower reason than this
      # comment used to give, and the difference mattered enough to cost coverage.
      #
      # What it used to say: "the egress gateway returns HTTP 400 for
      # cdn.playwright.dev, so `npx playwright install chromium` cannot fetch a
      # browser on these machines at all." That is FALSE, verified on a runner on
      # 2026-08-07 by downloading one: macOS chromium comes from Chrome for
      # Testing at `cdn.playwright.dev/builds/cft/<version>/mac-arm64/…` and
      # serves 206, as do firefox and webkit over the dbazure mirror. The 400 is
      # real on two paths Playwright never requests on macOS — the dbazure mirror
      # does not carry `builds/cft/*`, and the legacy
      # `builds/chromium/<rev>/chromium-mac-arm64.zip` is unpublished past rev
      # ~1205 — and somebody generalised one of those into a fleet fact. It then
      # sat in agent/instructions.md telling every session not to try, which is
      # why ISS-779 shipped two playbook-www PRs with the e2e suite unrun
      # (ISS-780).
      #
      # The real reason `browse` drives the cask instead is ordinary: a cask
      # Chrome is one install that every repo's `channel: "chrome"` resolves to,
      # whereas Playwright's Chromium is pinned per playwright-core version, so a
      # doctor entry for it would go stale the day any repo bumps Playwright —
      # exactly the 1194-vs-1217 mismatch ISS-780 was filed for. Sessions that
      # need the pinned browsers install them per repo; see agent/instructions.md.
      #
      # The half-extraction trap in the old comment IS real and is kept: an
      # interrupted install leaves the version directory behind, the next run
      # treats it as satisfied and exits 0, and the launch dies with SIGABRT on a
      # missing `Chromium Framework` dylib. `rm -rf` the version directory first.
      Tool.new(
        name: "google-chrome",
        paths: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"],
        required_by: "the browser `browse` drives (`channel: \"chrome\"`); Playwright's own " \
                     "Chromium cannot be downloaded on this fleet, so this IS the browser",
        producers: [],
        install: "brew install --cask google-chrome",
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
    ].freeze

    # Once a day, matching Agent::Maintenance. A toolchain does not change
    # between ticks, and `zsh -lc` costs a process — but a machine that has never
    # checked is due immediately, so a freshly provisioned runner reports on its
    # first tick rather than a day into pretending to work.
    CADENCE_SECONDS = 24 * 3600

    # Every probe below is a question a healthy binary answers in milliseconds,
    # and this check runs in Phase B ahead of reap and claim — so a tool that
    # does not answer must cost this machine one report, not every future tick
    # (ISS-740). The candidates are ordinary rather than exotic: `docker
    # --version` waits on a wedged daemon, `sbt --script-version` on a launcher
    # that wants the network, `zsh -lc` on a .zprofile that itself shells out to
    # something hung. 10 seconds is ~100x a slow answer and still under the 30
    # seconds between ticks.
    PROBE_TIMEOUT_SECONDS = 10

    Found = Struct.new(:tool, :path, :version, :unsupported_reason, keyword_init: true) do
      def present? = !path.nil?
      def missing? = path.nil?

      # Resolved, and unusable anyway. Kept distinct from `missing?` all the way
      # out to the operator: "install node" and "you have the wrong node" send
      # whoever is fixing the box to different places.
      def unsupported? = !unsupported_reason.nil?
    end

    Result = Struct.new(:at, :path, :found, keyword_init: true) do
      def missing_required = found.select { |f| f.missing? && f.tool.required? }.map(&:tool)
      def missing_optional = found.select { |f| f.missing? && f.tool.optional? }.map(&:tool)

      # Founds rather than Tools, because the reason and the version that produced
      # it are the whole content of the report and both live here.
      def unsupported = found.select { |f| f.unsupported? && f.tool.required? }

      def ok? = missing_required.empty? && unsupported.empty?

      # Producer keys whose PLAYBOOK cannot be carried out on this machine, deduped
      # and ordered as TOOLS orders them. This is the sentence the filed issue
      # leads with: "missing depsguard" is a fact about a laptop, "the depsguard
      # producer has never run" is the failure.
      #
      # An unsupported tool blocks its producers exactly as an absent one does —
      # `browserslist-update` shells out to `npx`, and it does not care whether
      # node is missing or wedged.
      def blocked_producers = (missing_required + unsupported.map(&:tool)).flat_map(&:producers).uniq

      # The one line the tick logs and the doctor headlines. Here rather than in
      # either caller so the two cannot drift, and so "MISSING" stops being
      # printed with nothing after it on a machine whose only problem is a
      # version (which is what a `missing_required`-only summary did).
      def summary
        return "all required tools present" if ok?
        parts = []
        parts << "MISSING #{missing_required.map(&:name).join(', ')}" unless missing_required.empty?
        parts << "UNSUPPORTED #{unsupported.map { |f| "#{f.tool.name} #{f.version}" }.join(', ')}" unless unsupported.empty?
        parts.join(" / ")
      end
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
    # `stderr: :inherit` rather than merged, and it matters: a .zprofile that
    # prints a deprecation warning would otherwise be spliced into the PATH every
    # probe below then scans, and the doctor would report a machine missing every
    # tool it has.
    def agent_path(env: ENV)
      result = Agent::Shell.capture("/bin/zsh", "-lc", "printf %s \"$PATH\"",
                                    timeout: PROBE_TIMEOUT_SECONDS, stderr: :inherit)
      return env["PATH"].to_s unless result.ok?
      out = result.output.strip
      out.empty? ? env["PATH"].to_s : out
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

    # Where one tool is looked for. A `paths` tool is probed at its fixed
    # locations and never on PATH: Chrome lives inside an .app bundle, so a PATH
    # scan would report it missing on every machine that has it.
    #
    # The executable test is the same one either way, deliberately — a file that
    # is present but not executable is not a usable tool no matter how it was
    # found, and reporting it installed sends whoever is fixing the box looking
    # in the wrong place.
    def resolve(tool, path:)
      return which(tool.name, path: path) unless tool.absolute?

      Array(tool.paths).map { |c| File.expand_path(c) }
                       .find { |c| File.file?(c) && File.executable?(c) }
    end

    # Best-effort `--version`. Still never used to decide present/absent: a tool
    # that resolves but refuses `--version` is installed, and treating it as
    # missing would file an issue about a working machine. A tool that HANGS on
    # `--version` is the same fact — it resolved — so a timeout drops the version
    # string and nothing else.
    #
    # It is no longer PURELY for the report, though: a `Tool#unsupported` is
    # judged from this string (ISS-781). The failure mode that buys is bounded in
    # the same direction as everything above — no string means no judgement, so a
    # tool this cannot read stays usable rather than being condemned on a guess.
    def version(path)
      result = Agent::Shell.capture(path, "--version", timeout: PROBE_TIMEOUT_SECONDS)
      return nil unless result.ok?
      result.output.lines.first.to_s.strip[0, 60]
    rescue StandardError
      nil
    end

    # `versions: false` therefore means "resolution only", and cannot report an
    # unsupported version — there is nothing to read one out of. Every caller that
    # passes it is a resolution test; the tick and the doctor both leave it on.
    def check(tools: TOOLS, now: Time.now, path: nil, versions: true)
      resolved = path || agent_path
      found = tools.map do |tool|
        binary = resolve(tool, path: resolved)
        found_version = binary && versions ? version(binary) : nil
        Found.new(tool: tool, path: binary, version: found_version,
                  unsupported_reason: binary && tool.unsupported_reason(found_version))
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
          "unsupported" => result.unsupported.map { |f| f.tool.name },
        },
        mode: 0600,
      )
    end

    # ---- what a human, or an issue, is told ----

    # Stable regardless of TOOLS' order, because it is half a dedup key: the
    # server does not re-file while a non-terminal issue with the same
    # fingerprint exists, and an order-dependent key would file a second issue
    # for the same machine the day someone reorders the list above.
    #
    # An unsupported tool contributes `name:unsupported` and deliberately NOT its
    # version. Keying on `node@26.6.0` would file a fresh issue on every patch
    # bump of a node that is broken for the same reason, and re-filing four times
    # while nobody has fixed it once is how a queue stops being read.
    def problem_key(result)
      (result.missing_required.map(&:name) +
       result.unsupported.map { |f| "#{f.tool.name}:unsupported" }).sort.join("+")
    end

    def issue_fingerprint(result, hostname) = "toolchain:#{hostname}:#{problem_key(result)}"

    def issue_title(result, hostname)
      parts = []
      parts << "is missing #{result.missing_required.map(&:name).sort.join(', ')}" unless result.missing_required.empty?
      parts << "cannot use #{result.unsupported.map { |f| "#{f.tool.name} #{f.version}" }.sort.join(', ')}" unless result.unsupported.empty?
      "dev-agent: #{hostname} #{parts.join(', and ')}"
    end

    # The body is written to be actionable without an ssh session: what is
    # missing, what it stops, what to type, and why nothing showed up as an
    # error. That last part is the point of the issue — anyone reading the queue
    # sees a quiet producer, and the whole finding is that quiet and healthy look
    # identical from there.
    def issue_body(result, hostname)
      lines = []
      unless result.missing_required.empty?
        lines += ["`#{hostname}` is missing #{result.missing_required.length} required tool(s).", ""]
        result.missing_required.each do |tool|
          lines << "- **#{tool.name}** — needed by #{tool.required_by}"
          lines << "  - looked for at: `#{tool.paths.join('`, `')}` (not on PATH)" if tool.absolute?
          lines << "  - install: `#{tool.install}`"
          lines << "  - blocks producer(s): #{tool.producers.map { |k| "`#{k}`" }.join(', ')}" unless tool.producers.empty?
        end
      end
      # Its own section, because the fix is not the same shape. "Missing" is
      # answered by installing something; this is answered by installing a
      # DIFFERENT VERSION of something already there, and an operator who reads
      # "missing node" on a box where `node --version` answers fine concludes the
      # report is broken and stops reading (ISS-781).
      unless result.unsupported.empty?
        lines += [""] unless lines.empty?
        lines += ["`#{hostname}` has #{result.unsupported.length} required tool(s) installed at a version " \
                  "that does not work here. Nothing is absent — these resolve, run, and answer " \
                  "`--version`.", ""]
        result.unsupported.each do |f|
          lines << "- **#{f.tool.name}** #{f.version} at `#{f.path}` — needed by #{f.tool.required_by}"
          lines << "  - why it cannot be used: #{f.unsupported_reason}"
          lines << "  - install: `#{f.tool.install}`"
          lines << "  - blocks producer(s): #{f.tool.producers.map { |k| "`#{k}`" }.join(', ')}" unless f.tool.producers.empty?
        end
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
      # EVERY `install:` line above is a SHELL line, not an argv, and an
      # autonomous session running one has to put it through `dev agent run-op`
      # — which takes argv. That translation is where ISS-894 went wrong and
      # ISS-896 came from, so the body does the translation rather than leaving
      # each session to invent one. The hints genuinely need a shell: NODE_INSTALL
      # contains both `&&` and `;`, and its leading `HOMEBREW_NO_AUTOREMOVE=1` is
      # load-bearing (ISS-852), so there is no argv spelling to fall back on.
      lines += ["", "**Each `install:` line above is a SHELL line** — several contain `&&`, `;` or a " \
                    "leading `VAR=1` assignment, none of which argv can express. An autonomous session " \
                    "runs one by handing it to a shell explicitly:",
                "", "```", "dev agent run-op <name> -- /bin/zsh -lc '<the install line>'", "```",
                "", "Do NOT translate it by prepending `env`: `dev agent run-op` takes argv, and " \
                    "`--env KEY=VALUE` is the flag for a single assignment. A failed run-op record " \
                    "returns this issue to the queue even if the session then fixed the machine.",
                "", "Resolution is the agent's own PATH (`/bin/zsh -lc`), NOT an interactive shell's — a tool " \
                    "that only a version manager loaded from `.zshrc` provides (nvm, rbenv, asdf) is present " \
                    "in your terminal and invisible to every process launchd starts. Install into homebrew.",
                "", "Verify with `dev agent doctor` on that machine.",
                "", "PATH checked:", "", "```",
                result.path.to_s.split(File::PATH_SEPARATOR).reject(&:empty?).uniq.join("\n"), "```"]
      lines.join("\n")
    end
  end
end
