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

  # Chrome's install must not be `npx playwright install`. On this fleet the
  # egress gateway 400s cdn.playwright.dev, so that command cannot fetch a browser
  # — and it exits 0 anyway when a half-extracted one is already on disk, which is
  # how ISS-608 lost twenty minutes to a SIGABRT about a missing dylib.
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
