#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Toolchain — the host prerequisites, as code (ISS-531).
#
# Every assertion here is about a SILENCE, because that is the failure this
# module exists to end. `depsguard` was absent on the runner for the producer's
# entire history: the check exited 2, the producer contract recorded
# `check_failed`, and `check_failed` is deliberately indistinguishable in the
# queue from a clean week — so a weekly supply-chain scan that had literally
# never executed looked exactly like a weekly supply-chain scan with nothing to
# report. The prerequisites were written down, in a plist comment, and a comment
# cannot be run.
class TestDevAgentToolchain < Minitest::Test
  include DevTestSupport

  T = Agent::Toolchain

  # Every other suite gets ToolchainGuard's healthy-machine stand-in for `check`,
  # so a tick test does not depend on what is installed on the box running it.
  # This file is ABOUT `check`, so it opts out — safely, because every assertion
  # below builds its own temp PATH and none of them touch the machine's.
  def before_setup
    super
    DevTestSupport::ToolchainGuard.uninstall
  end

  def with_agent_home
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_STATE_DIR"]
      ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
      begin
        yield root
      ensure
        ENV["DEV_AGENT_STATE_DIR"] = original
      end
    end
  end

  # A PATH holding exactly the named executables, so a probe can be exercised
  # without depending on what happens to be installed on the machine running the
  # suite — which is the very confound this module is about.
  def with_path(*names)
    Dir.mktmpdir do |dir|
      names.each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\necho #{name} 1.0\n")
        File.chmod(0755, path)
      end
      yield dir
    end
  end

  def tool(name, required: true, producers: [])
    T::Tool.new(name: name, required_by: "#{name} things", producers: producers,
                install: "brew install #{name}", required: required)
  end

  # A PATH holding one executable that answers `--version` with a string of the
  # caller's choosing. The version-dependent half of `check` (ISS-781) cannot be
  # exercised by `with_path`, whose stubs all report "1.0", and installing five
  # node majors on whatever machine runs this suite is not an option.
  def with_version(name, version_string)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\necho '#{version_string}'\n")
      File.chmod(0755, path)
      yield dir
    end
  end

  # Carries the REAL guard rather than a stand-in, so these assertions are about
  # the version boundary the fleet actually ships.
  def node_tool(producers: %w[browserslist-update])
    T::Tool.new(name: "node", required_by: "node things", producers: producers,
                install: "brew install node@24", unsupported: T::NODE_EXTRACT_DEADLOCK)
  end

  # ---- resolution ------------------------------------------------------------

  def test_a_binary_on_the_given_path_is_found
    with_path("depsguard") do |dir|
      result = T.check(tools: [tool("depsguard")], path: dir, versions: false)
      assert result.ok?
      assert_equal File.join(dir, "depsguard"), result.found.first.path
    end
  end

  def test_a_binary_absent_from_the_given_path_is_missing
    with_path do |dir|
      result = T.check(tools: [tool("depsguard")], path: dir, versions: false)
      refute result.ok?
      assert_equal %w[depsguard], result.missing_required.map(&:name)
    end
  end

  # A file that is present but not executable is not a usable tool, and reporting
  # it as installed would send whoever is fixing the machine looking in the wrong
  # place.
  def test_a_non_executable_file_does_not_count_as_installed
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "depsguard"), "not executable")
      result = T.check(tools: [tool("depsguard")], path: dir, versions: false)
      refute result.ok?
    end
  end

  # THE `node` BUG, as a test. nvm is sourced from .zshrc, which a login
  # NON-interactive shell (`/bin/zsh -lc`, what launchd runs) never reads. So
  # node was installed, on PATH in every human's terminal, and on no PATH the
  # agent has ever had. A doctor that probed ENV["PATH"] would have reported it
  # present to the person looking for it.
  def test_resolution_ignores_the_callers_own_path
    with_path("node") do |interactive_only|
      with_path do |agent_dir|
        original = ENV["PATH"]
        ENV["PATH"] = "#{interactive_only}#{File::PATH_SEPARATOR}#{original}"
        begin
          result = T.check(tools: [tool("node")], path: agent_dir, versions: false)
          refute result.ok?, "resolved against the caller's PATH instead of the agent's"
        ensure
          ENV["PATH"] = original
        end
      end
    end
  end

  # The fallback exists so a box whose login shell is broken reports something
  # close rather than every tool missing at once — which would file an issue
  # naming nine tools that are all installed.
  def test_agent_path_falls_back_to_this_process_when_the_login_shell_cannot_be_asked
    stub_shell(->(*) { raise Errno::ENOENT }) do
      assert_equal "/sentinel/bin", T.agent_path(env: { "PATH" => "/sentinel/bin" })
    end
  end

  # A login shell that HANGS is the same fact as one that cannot be asked, and it
  # is the more dangerous of the two: this check runs in Phase B ahead of reap
  # and claim, so before ISS-740 a `.zprofile` waiting on something that never
  # answers stopped the machine claiming work on every subsequent tick, with
  # nothing logged because a hang is not an exception.
  def test_agent_path_falls_back_when_the_login_shell_never_answers
    stub_shell(->(*) { shell_result(timed_out: true, timeout: T::PROBE_TIMEOUT_SECONDS) }) do
      assert_equal "/sentinel/bin", T.agent_path(env: { "PATH" => "/sentinel/bin" })
    end
  end

  # `docker --version` against a wedged daemon is the standing example. The tool
  # RESOLVED, so it is installed; the version string is decoration, and dropping
  # it is the whole cost of the deadline. Reporting the tool missing instead
  # would file an issue about a machine that has it.
  def test_a_version_probe_that_hangs_loses_the_string_and_nothing_else
    stub_shell(->(*) { shell_result(timed_out: true, timeout: T::PROBE_TIMEOUT_SECONDS) }) do
      assert_nil T.version("/opt/homebrew/bin/docker")
    end
  end

  # ---- prerequisites that are not on PATH ------------------------------------
  #
  # Google Chrome lives inside an .app bundle and has never been on anybody's
  # PATH, so a list that could only express "binary on PATH" would have had to
  # leave out the browser `browse` actually launches — and then report a healthy
  # machine that cannot render a page (ISS-608).

  def abs_tool(name, path, required: true)
    T::Tool.new(name: name, required_by: "#{name} things", producers: [],
                install: "brew install --cask #{name}", required: required, paths: [path])
  end

  def test_a_tool_at_a_fixed_path_is_found_with_no_path_entry_at_all
    Dir.mktmpdir do |dir|
      app = File.join(dir, "Chrome.app", "Contents", "MacOS", "Google Chrome")
      FileUtils.mkdir_p(File.dirname(app))
      File.write(app, "#!/bin/sh\n")
      File.chmod(0755, app)

      result = T.check(tools: [abs_tool("google-chrome", app)], path: "", versions: false)
      assert result.ok?
      assert_equal app, result.found.first.path
    end
  end

  def test_a_tool_absent_from_its_fixed_path_is_missing
    Dir.mktmpdir do |dir|
      result = T.check(tools: [abs_tool("google-chrome", File.join(dir, "nope"))],
                       path: "", versions: false)
      refute result.ok?
      assert_equal %w[google-chrome], result.missing_required.map(&:name)
    end
  end

  # The inversion that makes the fixed path worth having: a same-named binary
  # sitting on PATH must NOT satisfy it. Playwright launches `channel: "chrome"`
  # by absolute path, so a `google-chrome` shim on PATH would make the doctor
  # green on a machine where browse still cannot start a browser.
  def test_a_same_named_binary_on_path_does_not_satisfy_a_fixed_path_tool
    with_path("google-chrome") do |dir|
      result = T.check(tools: [abs_tool("google-chrome", File.join(dir, "not-the-app"))],
                       path: dir, versions: false)
      refute result.ok?, "resolved off PATH instead of the bundle path browse actually launches"
    end
  end

  # "not on the agent's PATH" is the wrong thing to tell someone whose Chrome is
  # simply not installed — it sends them editing .zprofile.
  def test_the_issue_body_says_where_a_fixed_path_tool_was_looked_for
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "Google Chrome")
      result = T.check(tools: [abs_tool("google-chrome", missing)], path: "", versions: false)
      body = T.issue_body(result, "mac-1")
      assert_includes body, missing
      assert_includes body, "not on PATH"
    end
  end

  # ---- required vs optional --------------------------------------------------

  # `openclaw` is best-effort by construction (Agent::Notify swallows its
  # absence). Failing provisioning over it would train whoever runs the doctor to
  # ignore its exit code, which costs the required tools their alarm.
  def test_an_optional_tool_is_reported_but_does_not_fail_the_check
    with_path do |dir|
      result = T.check(tools: [tool("openclaw", required: false)], path: dir, versions: false)
      assert result.ok?
      assert_equal %w[openclaw], result.missing_optional.map(&:name)
      assert_empty result.missing_required
    end
  end

  # ---- present, and the wrong version anyway (ISS-781) -----------------------
  #
  # The third state. Everything above this asks "is it installed"; node 26 is
  # installed, runs, answers `--version`, and deadlocks `playwright install`
  # while unpacking a browser — download fine, extraction wedged at 0% CPU
  # forever. Two sessions lost about an hour each to waiting it out before anyone
  # realised the installer was never going to return, and the doctor said
  # `node ok` on that machine throughout. Same silence as `depsguard`, one level
  # in: not a tool that is absent, a tool that is there and cannot do the job.

  # THE MEASUREMENT, as a test. The first five were run against the real
  # chromium archive on a runner on 2026-08-07 — same archive, same machine, same
  # minute: v22.14.0, v24.9.0 and v25.9.0 all extract it; v26.6.0 and v26.7.0
  # both wedge at the identical byte, so this is a Node >=26 regression and not a
  # Playwright bug. v24.19.0 is what `brew install node@24` actually gives today
  # and v27.0.0 is the boundary going the other way (a later major is refused
  # until somebody measures it, which is the safe direction).
  def test_the_node_versions_that_extract_a_browser_pass_and_the_ones_that_hang_do_not
    { "v22.14.0" => true, "v24.9.0" => true, "v25.9.0" => true, "v24.19.0" => true,
      "v26.6.0" => false, "v26.7.0" => false, "v27.0.0" => false }.each do |version, usable|
      with_version("node", version) do |dir|
        result = T.check(tools: [node_tool], path: dir)
        assert_equal usable, result.ok?, "node #{version} should#{usable ? '' : ' not'} be usable"
      end
    end
  end

  # The distinction that decides where an operator looks. `node` resolves on this
  # machine — reporting it MISSING would send someone to install a node they
  # already have, conclude the report is broken, and stop reading it.
  def test_an_unusable_tool_is_never_reported_as_missing
    with_version("node", "v26.6.0") do |dir|
      result = T.check(tools: [node_tool], path: dir)
      refute result.ok?
      assert_empty result.missing_required
      assert_equal %w[node], result.unsupported.map { |f| f.tool.name }
      assert result.found.first.present?, "an unsupported tool is still present"

      refute_includes T.issue_title(result, "mac-1"), "missing"
      body = T.issue_body(result, "mac-1")
      refute_includes body, "is missing"
      assert_includes body, "v26.6.0"
      assert_includes body, "brew install node@24"
    end
  end

  # The reason has to travel to the operator, because "wrong version" alone does
  # not tell anyone whether they can ignore it. It names what breaks, and bounds
  # it: node 26 runs everything else here, Playwright included once browsers are
  # on disk (playbook-www's suite is 34 passed on 26.6.0) — only the installer
  # hangs. A reason that overclaimed would be one an operator correctly ignores.
  def test_the_reason_names_what_breaks_and_does_not_overclaim
    with_version("node", "v26.6.0") do |dir|
      reason = T.check(tools: [node_tool], path: dir).unsupported.first.unsupported_reason
      assert_includes reason, "playwright install"
      assert_includes reason, "ISS-781"
      assert_includes reason, "24"
    end
  end

  # A version this cannot read is NOT a condemnation. The rest of this module is
  # emphatic that a tool refusing `--version` is still installed, and guessing
  # here would file an issue about a working machine.
  def test_a_tool_whose_version_cannot_be_read_stays_usable
    with_path("node") do |dir| # stub answers "node 1.0", not a node version at all
      assert T.check(tools: [node_tool], path: dir).ok?
    end
    assert_nil T.major("not a version")
    assert_nil node_tool.unsupported_reason(nil)
  end

  # `versions: false` is resolution-only, so it has nothing to judge a version
  # from. It must not therefore report the tool BROKEN — every caller passing it
  # is testing resolution, and a false positive there would fail them all.
  def test_resolution_only_mode_cannot_condemn_a_version
    with_version("node", "v26.6.0") do |dir|
      assert T.check(tools: [node_tool], path: dir, versions: false).ok?
    end
  end

  # `browserslist-update` shells out through node; it does not care whether node
  # is absent or wedged. Leaving unsupported tools out of this would report a
  # producer as fine on a machine where it cannot run.
  def test_an_unusable_tool_blocks_its_producers_exactly_as_an_absent_one_does
    with_version("node", "v26.6.0") do |dir|
      result = T.check(tools: [node_tool], path: dir)
      assert_equal %w[browserslist-update], result.blocked_producers
    end
  end

  # Node 26.6.0 and 26.7.0 are one finding, not two. Keying on the exact version
  # would file a fresh issue on every patch bump of a node broken for the same
  # reason, and re-filing four times while nobody has fixed it once is how a
  # queue stops being read.
  def test_a_patch_bump_of_a_broken_node_does_not_file_a_second_issue
    with_version("node", "v26.6.0") do |a|
      with_version("node", "v26.7.0") do |b|
        first = T.check(tools: [node_tool], path: a)
        second = T.check(tools: [node_tool], path: b)
        assert_equal T.issue_fingerprint(first, "mac-1"), T.issue_fingerprint(second, "mac-1")
      end
    end
  end

  # An absent node and an unusable node are different problems with different
  # fixes. One fingerprint across both would leave the second invisible behind
  # the first one's non-terminal issue.
  def test_missing_and_unusable_are_different_fingerprints
    with_path do |absent|
      with_version("node", "v26.6.0") do |wrong|
        gone = T.check(tools: [node_tool], path: absent)
        unusable = T.check(tools: [node_tool], path: wrong)
        refute_equal T.issue_fingerprint(gone, "mac-1"), T.issue_fingerprint(unusable, "mac-1")
      end
    end
  end

  # What the tick logs. A summary built only from `missing_required` printed
  # "MISSING " with nothing after it on a machine whose sole problem was a
  # version — an operator reading that line learns nothing at all.
  def test_the_logged_summary_names_the_unusable_version
    with_version("node", "v26.6.0") do |dir|
      summary = T.check(tools: [node_tool], path: dir).summary
      assert_includes summary, "node"
      assert_includes summary, "v26.6.0"
      refute_includes summary, "MISSING"
    end
    with_path("node") do |dir|
      assert_equal "all required tools present", T.check(tools: [node_tool], path: dir).summary
    end
  end

  def test_the_marker_records_an_unusable_tool
    with_agent_home do
      with_version("node", "v26.6.0") do |dir|
        T.record(T.check(tools: [node_tool], path: dir))
        assert_equal %w[node], T.state["unsupported"]
        assert_equal [], T.state["missing"]
      end
    end
  end

  # THE FLEET ENTRY, not a stand-in. Plain `brew install node` is what put a
  # Current release on these runners, and Current is the broken one — so the
  # shipped install command has to name the LTS, and the shipped node entry has
  # to carry the guard at all.
  def test_the_fleets_node_is_pinned_to_the_lts_and_guarded
    node = T::TOOLS.find { |t| t.name == "node" }
    assert_equal T::NODE_EXTRACT_DEADLOCK, node.unsupported, "node ships without the version guard"
    assert_includes node.install, "node@24"
    refute_match(/brew install node(\s|$)/, node.install,
                 "installs Current, which is the version that deadlocks")
    assert_includes node.install, "link", "node@24 is keg-only; without a link it never reaches the login PATH"

    # npx deliberately carries no guard: `npx --version` prints NPM's version, so
    # the node check would be reading the wrong number off it.
    assert_nil T::TOOLS.find { |t| t.name == "npx" }.unsupported
  end

  # node and npx come out of one formula, so they are one remediation. Held as
  # ONE string because the copy that gets missed is what ISS-852 is: the
  # autoremove suppression below was applied to a line that existed twice.
  def test_node_and_npx_ship_the_same_remediation
    node, npx = %w[node npx].map { |n| T::TOOLS.find { |t| t.name == n } }
    assert_equal node.install, npx.install
    assert_equal T::NODE_INSTALL, node.install
  end

  # ISS-852. `brew uninstall` runs an autoremove pass afterwards, and that pass
  # sweeps every formula flagged `installed_as_dependency` that nothing depends
  # on any more — not just the tree the uninstall orphaned. On a Mac on
  # 2026-08-07 this line took `tailscale`'s symlinks and receipt with it, and
  # nothing looked broken until the CLI was invoked. Which formulae get swept is
  # a property of the machine's receipt flags, so it is a different tool every
  # time and silent every time. Asserted over EVERY tool, not just node: the
  # hazard belongs to `brew uninstall` appearing in a command we ship at all.
  def test_no_shipped_remediation_lets_brew_autoremove_run
    T::TOOLS.each do |t|
      next unless t.install.to_s.include?("brew uninstall")
      assert_match(/HOMEBREW_NO_AUTOREMOVE=1 brew uninstall/, t.install,
                   "#{t.name}: `brew uninstall` autoremoves unrelated formulae fleet-wide (ISS-852)")
    end
  end

  # ISS-897, and it is ISS-852's hazard one dependency edge further out. The
  # `--ignore-dependencies` that lets the uninstall run at all is exactly what
  # leaves the dependents behind, and `brew uninstall node` takes
  # <prefix>/opt/node with the keg — so every formula shebanged at
  # `#!/opt/homebrew/opt/node/bin/node` (mongosh, on a Mac here) answers `bad
  # interpreter` from that moment, and this doctor reports the box all-green
  # because mongosh is not one of the tools it checks. Asserted over EVERY tool
  # for the same reason as the autoremove one: the hazard belongs to
  # `brew uninstall <formula>` appearing in anything this fleet ships, not to
  # node.
  def test_a_shipped_uninstall_puts_the_formulas_opt_name_back
    T::TOOLS.each do |t|
      formula = t.install.to_s[/brew uninstall(?:\s+--\S+)*\s+(\S+)/, 1]
      next if formula.nil?
      assert_includes t.install, "opt/#{formula}",
                      "#{t.name}: `brew uninstall #{formula}` deletes <prefix>/opt/#{formula}, and " \
                      "every formula shebanged into it breaks silently (ISS-897)"
    end
  end

  # ---- the relink, executed --------------------------------------------------
  #
  # The four assertions below run the SHIPPED string under /bin/sh against a
  # throwaway brew prefix. Only `$(brew --prefix)` is substituted — the guard,
  # the flags and the link target are the characters an operator pastes, because
  # a test that restated the logic in Ruby would pass on a hint with a typo in it.

  # A prefix laid out the way brew lays one out: a versioned keg, and the opt
  # name brew itself maintains pointing into it.
  def with_brew_prefix(keg: "24.19.0")
    Dir.mktmpdir do |prefix|
      FileUtils.mkdir_p(File.join(prefix, "Cellar", "node@24", keg, "bin"))
      File.write(File.join(prefix, "Cellar", "node@24", keg, "bin", "node"), "#!/bin/sh\n")
      FileUtils.mkdir_p(File.join(prefix, "opt"))
      File.symlink("../Cellar/node@24/#{keg}", File.join(prefix, "opt", "node@24"))
      yield prefix
    end
  end

  def relink(prefix)
    script = T::NODE_OPT_RELINK.gsub('$(brew --prefix)', prefix)
    assert system("/bin/sh", "-c", script, out: File::NULL, err: File::NULL),
           "the shipped relink exited non-zero: #{script}"
  end

  # The state `brew uninstall --ignore-dependencies node` leaves behind: opt/node
  # simply gone. This is the whole bug — the dependents' shebangs point here.
  def test_the_relink_restores_a_node_removed_by_the_uninstall
    with_brew_prefix do |prefix|
      refute File.exist?(File.join(prefix, "opt", "node"))
      relink(prefix)
      assert File.exist?(File.join(prefix, "opt", "node", "bin", "node")),
             "a `#!/opt/homebrew/opt/node/bin/node` shebang still does not resolve"
    end
  end

  # It is appended to a command an operator may run more than once — and to one
  # whose earlier halves are `;`-separated precisely so a partly-provisioned
  # machine can be re-run.
  def test_the_relink_is_idempotent
    with_brew_prefix do |prefix|
      2.times { relink(prefix) }
      assert File.exist?(File.join(prefix, "opt", "node", "bin", "node"))
    end
  end

  # `[ -e ]` follows the symlink, so a dangling opt/node is not "already there".
  # A `[ -L ]`/`-h` test would see a link, decide the machine was fine, and leave
  # the exact broken state ISS-897 reports.
  def test_the_relink_replaces_a_dangling_opt_node
    with_brew_prefix do |prefix|
      File.symlink("../Cellar/node/26.6.0", File.join(prefix, "opt", "node"))
      relink(prefix)
      assert File.exist?(File.join(prefix, "opt", "node", "bin", "node"))
    end
  end

  # The other direction, and the reason the guard is there at all. A LIVE
  # opt/node means the `node` formula is installed — the uninstall failed, or
  # somebody wants it — and repointing it at node@24 would leave brew's own view
  # of an installed formula lying, with the link deleted again the next time that
  # formula is removed.
  def test_the_relink_never_repoints_a_live_opt_node
    with_brew_prefix do |prefix|
      FileUtils.mkdir_p(File.join(prefix, "Cellar", "node", "26.6.0", "bin"))
      File.write(File.join(prefix, "Cellar", "node", "26.6.0", "bin", "node"), "#!/bin/sh\n")
      File.symlink("../Cellar/node/26.6.0", File.join(prefix, "opt", "node"))
      relink(prefix)
      assert_equal "../Cellar/node/26.6.0", File.readlink(File.join(prefix, "opt", "node"))
    end
  end

  # Why it links the opt NAME and not the Cellar path. brew rewrites
  # opt/node@24 on every patch bump; a link to `../Cellar/node@24/24.19.0` would
  # dangle the first time node@24 moved, which is the same failure this fixes
  # arriving later and with nobody having run anything.
  def test_the_relink_survives_a_node_24_patch_bump
    with_brew_prefix do |prefix|
      relink(prefix)
      FileUtils.mkdir_p(File.join(prefix, "Cellar", "node@24", "24.20.0", "bin"))
      File.write(File.join(prefix, "Cellar", "node@24", "24.20.0", "bin", "node"), "#!/bin/sh\n")
      File.unlink(File.join(prefix, "opt", "node@24"))
      File.symlink("../Cellar/node@24/24.20.0", File.join(prefix, "opt", "node@24"))
      FileUtils.rm_rf(File.join(prefix, "Cellar", "node@24", "24.19.0"))

      assert File.exist?(File.join(prefix, "opt", "node", "bin", "node")),
             "opt/node dangled after node@24 moved — it is pinned to a Cellar version"
    end
  end

  # ---- what the operator and the issue are told ------------------------------

  def test_blocked_producers_are_named_and_deduped
    with_path do |dir|
      tools = [tool("node", producers: %w[browserslist-update]),
               tool("npx", producers: %w[browserslist-update]),
               tool("depsguard", producers: %w[depsguard])]
      result = T.check(tools: tools, path: dir, versions: false)
      assert_equal %w[browserslist-update depsguard], result.blocked_producers
    end
  end

  # The fingerprint is a dedup key the SERVER honours — it does not re-file while
  # a non-terminal issue carries the same one. Ordering it by TOOLS' order would
  # file a duplicate for an unchanged machine the day someone reorders the list.
  def test_the_fingerprint_is_stable_under_reordering
    with_path do |dir|
      a = T.check(tools: [tool("npx"), tool("depsguard")], path: dir, versions: false)
      b = T.check(tools: [tool("depsguard"), tool("npx")], path: dir, versions: false)
      assert_equal T.issue_fingerprint(a, "mac-1"), T.issue_fingerprint(b, "mac-1")
    end
  end

  # Two machines missing the same tool are two problems, each fixed by hand on
  # its own box. One fingerprint between them would file for whichever ran first
  # and leave the other invisible — which is the shape of the bug being fixed.
  def test_the_fingerprint_is_per_machine
    with_path do |dir|
      result = T.check(tools: [tool("depsguard")], path: dir, versions: false)
      refute_equal T.issue_fingerprint(result, "mac-1"), T.issue_fingerprint(result, "mac-2")
    end
  end

  # A partially provisioned machine must file again for what is still missing.
  # A key naming only the host would stay non-terminal after the first fix and
  # silently absorb the rest.
  def test_fixing_one_tool_changes_the_fingerprint
    with_path do |dir|
      both = T.check(tools: [tool("depsguard"), tool("node")], path: dir, versions: false)
      one = T.check(tools: [tool("node")], path: dir, versions: false)
      refute_equal T.issue_fingerprint(both, "mac-1"), T.issue_fingerprint(one, "mac-1")
    end
  end

  def test_the_issue_body_carries_the_install_command_and_what_is_blocked
    with_path do |dir|
      result = T.check(tools: [tool("depsguard", producers: %w[depsguard])], path: dir, versions: false)
      body = T.issue_body(result, "mac-1")
      assert_includes body, "brew install depsguard"
      assert_includes body, "`depsguard`"
      assert_includes body, "check_failed"
      assert_includes body, "dev agent doctor"
    end
  end

  # ---- cadence ---------------------------------------------------------------

  # A machine that has never checked checks on its first tick. Provisioning a
  # runner and waiting a day to learn it cannot work is the failure mode, not the
  # remedy.
  def test_a_machine_that_has_never_checked_is_due_immediately
    with_agent_home { assert T.due?(now: Time.now) }
  end

  def test_the_check_is_once_a_day
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do
      with_path do |dir|
        T.record(T.check(tools: [tool("gh")], path: dir, now: now, versions: false))
        refute T.due?(now: now + 3600)
        assert T.due?(now: now + T::CADENCE_SECONDS + 1)
      end
    end
  end

  def test_the_marker_records_what_was_missing
    with_agent_home do
      with_path do |dir|
        T.record(T.check(tools: [tool("depsguard"), tool("openclaw", required: false)],
                         path: dir, now: Time.utc(2026, 8, 5), versions: false))
        state = T.state
        assert_equal %w[depsguard], state["missing"]
        assert_equal %w[openclaw], state["missing_optional"]
      end
    end
  end

  # ---- the producers a tool names ---------------------------------------------
  #
  # The guard that these keys still EXIST is gone, and knowingly: the registry is
  # platform rows now (ISS-521/ISS-526), so devops has nothing local to check them
  # against and a live API call is not something a unit test should make. The keys
  # are display strings here — the sentence a filed issue leads with — so a stale
  # one is a misleading message rather than a broken producer.

  # The two producers ISS-531 and its comment found broken. If either loses its
  # prerequisite here, the gap becomes silent again.
  def test_the_ported_producers_that_shell_out_declare_their_binaries
    named = T::TOOLS.flat_map(&:producers).uniq
    assert_includes named, "depsguard"
    assert_includes named, "browserslist-update"
  end

  # `api` is the prerequisite that used to be documented in the prompt of the
  # `codegen-sync-weekly` openclaw cron, which ISS-396 retired as a duplicate of
  # the `codegen-sync` producer. Deleting a prompt deletes what it knew, so the
  # requirement moved here. Without it every backend in the sweep comes back
  # `api failed in .` and every frontend that depends on one is skipped
  # (2026-07-08), on a box where `dev` itself starts perfectly well — the plist
  # invokes it by absolute path.
  def test_the_codegen_sweeps_regen_binary_is_declared
    api = T::TOOLS.find { |t| t.name == "api" }
    refute_nil api, "codegen sync shells out to `api`; a runner without it regenerates nothing"
    assert api.required?, "a missing `api` fails the whole sweep, not one optional feature"
  end

  # The visual-inspection path (ISS-608). Both halves are declared or the gap
  # goes silent again in the exact way it was silent before: `browse` was
  # `command not found` on the runners for the whole life of CLAUDE.md's "Visual
  # Inspection" section, and this doctor reported "all required tools present" on
  # that machine — because a session that cannot render a page does not fail, it
  # ships a layout change nobody looked at.
  def test_the_visual_inspection_path_is_declared
    browse = T::TOOLS.find { |t| t.name == "browse" }
    refute_nil browse, "without `browse` a UI session verifies a change it never saw, silently"
    assert browse.required?

    chrome = T::TOOLS.find { |t| t.name == "google-chrome" }
    refute_nil chrome, "`browse` on PATH is only half of it — it still needs a browser to drive"
    assert chrome.required?
  end

  # Copied from playwright-core's registry, not guessed: this is the literal path
  # Playwright resolves `channel: "chrome"` to on darwin, which is what browse.mjs
  # launches. If someone "tidies" it to a directory or a PATH lookup, the doctor
  # goes green on a machine where browse cannot start.
  def test_chromes_probe_is_the_path_playwright_actually_launches
    chrome = T::TOOLS.find { |t| t.name == "google-chrome" }
    assert chrome.absolute?, "Chrome is an .app bundle; a PATH scan reports it missing everywhere"
    assert_equal ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"], chrome.paths
  end

  # Chrome's install must not be `npx playwright install`, and the reason is NOT
  # the one this comment used to give. It claimed the egress gateway 400s
  # cdn.playwright.dev; ISS-780 disproved that by downloading a browser from it.
  # The reason that survives is that Playwright's Chromium is pinned per
  # playwright-core version, so naming it here would put a version in the doctor
  # that goes stale the day any repo bumps Playwright — which is the 1194-vs-1217
  # mismatch ISS-780 was filed for. The cask is version-free and every repo's
  # `channel: "chrome"` resolves to it. (The half-extract-then-exit-0 trap that
  # cost ISS-608 twenty minutes is real and still documented on the tool.)
  def test_chrome_is_installed_from_the_cask_not_from_the_playwright_cdn
    chrome = T::TOOLS.find { |t| t.name == "google-chrome" }
    assert_includes chrome.install, "--cask google-chrome"
    refute_includes chrome.install, "playwright"
  end

  def test_every_tool_carries_an_install_command_and_a_reason
    T::TOOLS.each do |t|
      refute_empty t.install.to_s, "#{t.name}: no install command — the one question a broken box asks"
      refute_empty t.required_by.to_s, "#{t.name}: no required_by"
    end
  end
end
