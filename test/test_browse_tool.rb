#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# BrowseTool — the `browse` shim, and its refusal to fail quietly (ISS-658).
#
# The bug was not that browse was broken. browse works, and has all along: it
# lives in the claude repo with its node_modules committed, and drives the system
# Chrome. The bug was that nothing put it on a PATH, so on every runner it was
# `command not found` — while CLAUDE.md went on telling each session to screenshot
# the page it had just changed. ISS-656 shipped a change to a sign form's error
# display having never once seen it render.
#
# So most of what is asserted here is about the SENTENCE a broken machine gets.
# A shim that dies with `Cannot find module 'playwright'` sends a session off to
# install playwright; one that says which of four things is absent and what to
# type gets fixed. That is the same argument Agent::Toolchain makes about the
# plist comment, one layer down.
class TestBrowseTool < Minitest::Test
  include DevTestSupport

  B = BrowseTool

  # A claude checkout with as much of the tool present as the test wants. The
  # override is Agent::Paths' own test seam, so this exercises the real
  # resolution rather than a parallel copy of it.
  def with_checkout(entrypoint: true, playwright: true)
    Dir.mktmpdir do |root|
      repo = File.join(root, "claude")
      tool = File.join(repo, "tools", "browse")
      FileUtils.mkdir_p(tool)
      File.write(File.join(tool, "browse.mjs"), "// stand-in\n") if entrypoint
      FileUtils.mkdir_p(File.join(tool, "node_modules", "playwright")) if playwright
      original = ENV["DEV_AGENT_CLAUDE_REPO"]
      ENV["DEV_AGENT_CLAUDE_REPO"] = repo
      begin
        yield repo
      ensure
        ENV["DEV_AGENT_CLAUDE_REPO"] = original
      end
    end
  end

  # Launching a real browser inside the suite would make these tests depend on
  # what is installed on the machine running them — the confound the module is
  # about. Every test that gets past the file checks says here what the browser
  # did.
  def with_browser(ok:, detail: "stubbed")
    stub_singleton(B, :browser_requirement, lambda {
      B::Requirement.new(name: "browser", ok: ok, detail: detail,
                         fix: "brew install --cask google-chrome")
    }) { yield }
  end

  def named(requirements, name) = requirements.find { |r| r.name == name }

  # ---- what it needs ---------------------------------------------------------

  def test_the_tool_is_resolved_out_of_the_claude_checkout
    with_checkout do |repo|
      assert_equal File.join(repo, "tools", "browse", "browse.mjs"), B.entrypoint
      assert_equal File.join(repo, "tools", "browse", "node_modules", "playwright"), B.playwright_module
    end
  end

  def test_a_machine_with_everything_can_run_it
    with_checkout do
      with_browser(ok: true) do
        assert B.requirements.all?(&:ok?)
        assert_equal 0, B.report(io: StringIO.new)
      end
    end
  end

  def test_a_missing_checkout_names_the_clone_command
    with_checkout(entrypoint: false, playwright: false) do |repo|
      failed = B.requirements.reject(&:ok?)
      assert_equal %w[browse.mjs playwright], failed.map(&:name)
      assert_includes named(failed, "browse.mjs").fix, "gh repo clone mbryzek/claude #{repo}"
    end
  end

  def test_a_missing_playwright_package_names_the_install_command
    with_checkout(playwright: false) do |repo|
      failed = B.requirements.reject(&:ok?)
      assert_equal %w[playwright], failed.map(&:name)
      assert_includes named(failed, "playwright").fix, "npm install --prefix #{File.join(repo, 'tools', 'browse')}"
    end
  end

  # Probing the browser before the things the probe needs are in place answers a
  # question nobody asked: "chrome is missing" on a machine whose actual problem
  # is an absent checkout starts the fix in the wrong place, and costs a browser
  # launch to get there.
  def test_the_browser_is_not_probed_until_what_it_needs_is_there
    with_checkout(playwright: false) do
      stub_singleton(B, :browser_requirement, -> { flunk "probed the browser with no playwright package" }) do
        refute named(B.requirements, "browser")
      end
    end
  end

  def test_the_browser_probe_can_be_skipped_for_the_file_checks_alone
    with_checkout do
      stub_singleton(B, :browser_requirement, -> { flunk "probed the browser when asked not to" }) do
        assert_equal %w[browse.mjs playwright node], B.requirements(browser: false).map(&:name)
      end
    end
  end

  # ---- the browser probe -----------------------------------------------------

  # THE PROBE MUST LAUNCH WHAT browse LAUNCHES. browse.mjs uses the SYSTEM Chrome
  # (`channel: "chrome"`) because this network's egress gateway rejects the
  # Playwright CDN with a 400, so there is no bundled chromium to fall back on. A
  # probe written against the bundled browser would call this very runner broken:
  # `chromium.executablePath()` here names a revision that is not on disk, while
  # `browse https://example.com` returns a screenshot.
  def test_the_probe_launches_the_same_browser_browse_does
    with_checkout do
      script = B.probe_script
      assert_includes script, "BROWSE_CHANNEL"
      assert_includes script, '"chrome"'
      assert_includes script, B.playwright_module,
                      "requiring playwright by name would resolve against whatever cwd the probe was spawned in"
      refute_includes script, "executablePath"
    end
  end

  # One line, and the one that says what happened. The probe emits exactly one by
  # construction, so a second line means node got in first with a stack trace —
  # and "at Module._resolveFilename" is not an answer to "why can I not take a
  # screenshot".
  def test_a_browser_that_will_not_launch_is_reported_with_the_headline_not_the_stack
    with_checkout do
      stub_singleton(Util, :run_with_timeout, ->(*_a, **_k) { ["browserType.launch: chrome not found\n  at foo\n", :failed] }) do
        chrome = B.browser_requirement
        refute chrome.ok?
        assert_equal "browserType.launch: chrome not found", chrome.detail
        assert_includes chrome.fix, "brew install --cask google-chrome"
      end
    end
  end

  # A probe that says nothing at all still has to say something. Silence here
  # would render as a blank reason in `dev agent doctor` and in the filed issue.
  def test_a_silent_failure_still_reports_a_reason
    with_checkout do
      stub_singleton(Util, :run_with_timeout, ->(*_a, **_k) { ["", :failed] }) do
        refute B.browser_requirement.ok?
        refute_empty B.browser_requirement.detail
      end
    end
  end

  # A browser that starts and wedges is the third case, and the expensive one:
  # `dev agent tick` runs this probe once a day while holding the work lock, so
  # an unbounded launch would stall every job that runner was going to claim.
  def test_a_browser_that_never_answers_is_bounded
    with_checkout do
      stub_singleton(Util, :run_with_timeout, ->(*_a, **_k) { [nil, :timed_out] }) do
        chrome = B.browser_requirement
        refute chrome.ok?
        assert_includes chrome.detail, "did not answer within #{B::PROBE_TIMEOUT_SECONDS}s"
      end
    end
  end

  # ---- what it says ----------------------------------------------------------

  # The contract with Agent::Toolchain, which runs this as `browse --check` and
  # reports the last non-empty line as the reason the tool is unusable. The table
  # above it is for a human; this line is what reaches the doctor and the issue.
  def test_the_last_line_of_check_is_the_one_line_summary
    with_checkout(playwright: false) do
      io = StringIO.new
      assert_equal 1, B.report(io: io)
      assert_equal B.summary(B.requirements.reject(&:ok?)), io.string.lines.map(&:strip).reject(&:empty?).last
    end
  end

  def test_the_check_reports_every_requirement_not_only_the_broken_one
    with_checkout do
      with_browser(ok: false, detail: "no chrome") do
        io = StringIO.new
        B.report(io: io)
        %w[browse.mjs playwright node browser].each { |n| assert_includes io.string, n }
        assert_includes io.string, "brew install --cask google-chrome"
      end
    end
  end

  # ---- the entry point -------------------------------------------------------

  def test_a_machine_that_cannot_run_it_is_told_so_instead_of_shown_a_stack_trace
    with_checkout(entrypoint: false, playwright: false) do
      err = StringIO.new
      assert_equal 1, B.main(["http://localhost:3000"], err: err)
      assert_includes err.string, "browse cannot run"
      assert_includes err.string, "gh repo clone mbryzek/claude"
      assert_includes err.string, "ISS-658"
      refute_includes err.string, "Cannot find module"
    end
  end

  # `--help` is the one invocation that must survive a browser-less machine: it
  # is what a session runs to learn the flags, and gating it on Chrome would hide
  # the only message that explains them.
  def test_usage_does_not_require_a_browser
    with_checkout do
      stub_singleton(B, :browser_requirement, -> { flunk "probed the browser for --help" }) do
        stub_singleton(B, :exec_browse, ->(argv) { throw :execed, ["node", B.entrypoint, *argv] }) do
          assert_equal ["node", B.entrypoint, "--help"],
                       catch(:execed) { B.main(["--help"]) }
        end
      end
    end
  end

  # `exec`, not a wrapper: browse's own stdout, stderr and exit code reach the
  # caller untouched rather than through a shim that would have to reproduce all
  # three, and every flag it grows arrives here without this file being edited.
  def test_a_healthy_machine_hands_the_arguments_straight_to_the_tool
    with_checkout do
      with_browser(ok: true) do
        stub_singleton(B, :exec_browse, ->(argv) { throw :execed, ["node", B.entrypoint, *argv] }) do
          assert_equal ["node", B.entrypoint, "http://localhost:5173", "--device", "mobile"],
                       catch(:execed) { B.main(%w[http://localhost:5173 --device mobile]) }
        end
      end
    end
  end

  # `Agent::Toolchain#version` calls `--version` on every tool it resolves.
  # Passing that through to browse.mjs, which has no such flag, would preflight
  # and launch a browser to fail — so `dev agent doctor` would start Chrome twice
  # every run and learn nothing from the first one.
  def test_version_is_answered_without_starting_a_browser
    with_checkout do
      stub_singleton(B, :browser_requirement, -> { flunk "started a browser to answer --version" }) do
        io = StringIO.new
        assert_equal 0, B.main(["--version"], io: io)
        assert_includes io.string, B.entrypoint
      end
    end
  end

  def test_check_takes_no_other_arguments
    err = StringIO.new
    assert_equal 2, B.main(%w[--check http://localhost:3000], err: err)
    assert_includes err.string, "usage:"
  end
end
