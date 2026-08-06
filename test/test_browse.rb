#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Browse — the launcher that puts the visual-inspection tool on the agent's PATH
# (ISS-608).
#
# Every assertion here is about an ERROR MESSAGE, which is unusual for a test and
# is the point of this one. The failure being fixed was not that browse was
# broken — browse works on these machines and always did. It was that a session
# looking for it got `command not found`, went and hand-rolled a Playwright
# harness, and hit a SIGABRT about a missing dylib with nothing anywhere saying
# "the CDN is blocked, use the system Chrome". Twenty minutes of a session budget
# went into rediscovering that, twice. So what this guards is that each way of
# being broken names the literal command that fixes it.
class TestBrowse < Minitest::Test
  include DevTestSupport

  # A claude checkout with browse.mjs where Browse expects it, plus a PATH that
  # holds exactly the named binaries — so none of this depends on how the machine
  # running the suite happens to be provisioned.
  def with_machine(impl: true, node: true, chrome: true)
    Dir.mktmpdir do |root|
      claude = File.join(root, "claude")
      if impl
        FileUtils.mkdir_p(File.join(claude, "tools", "browse"))
        File.write(File.join(claude, "tools", "browse", "browse.mjs"), "// stub\n")
      end

      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      if node
        File.write(File.join(bin, "node"), "#!/bin/sh\necho v0\n")
        File.chmod(0755, File.join(bin, "node"))
      end

      chrome_path = File.join(root, "Chrome.app", "Contents", "MacOS", "Google Chrome")
      if chrome
        FileUtils.mkdir_p(File.dirname(chrome_path))
        File.write(chrome_path, "#!/bin/sh\necho Chrome\n")
        File.chmod(0755, chrome_path)
      end

      with_env("DEV_AGENT_CLAUDE_REPO" => claude, "DEV_BROWSE_CHROME" => chrome_path) do
        yield(path: bin, env: ENV.to_h.merge("DEV_BROWSE_CHROME" => chrome_path))
      end
    end
  end

  def with_env(pairs)
    original = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  # ---- resolution ------------------------------------------------------------

  def test_a_fully_provisioned_machine_is_not_blocked
    with_machine do |path:, env:|
      assert_nil Browse.blocking_reason(path: path, env: env)
    end
  end

  def test_the_impl_is_resolved_inside_the_claude_checkout
    with_machine do |path:, env:|
      assert_equal File.join(Agent::Paths.claude_repo, "tools", "browse", "browse.mjs"),
                   Browse.impl_path
    end
  end

  # ---- each way of being broken names its own fix ----------------------------

  def test_a_machine_with_no_claude_checkout_is_told_to_clone_it
    with_machine(impl: false) do |path:, env:|
      assert_equal :no_impl, Browse.blocking_reason(path: path, env: env)
      assert_includes Browse.message(reason: :no_impl), "gh repo clone mbryzek/claude"
    end
  end

  # The node entry deliberately says "NOT nvm". A node that only .zshrc provides
  # is on PATH in a human's terminal and on no PATH launchd ever hands the agent,
  # which is the confound Agent::Toolchain's module comment exists for — someone
  # debugging this by hand would otherwise see `node` working and look elsewhere.
  def test_a_machine_without_node_is_told_to_brew_it_not_nvm_it
    with_machine(node: false) do |path:, env:|
      assert_equal :no_node, Browse.blocking_reason(path: path, env: env)
      message = Browse.message(reason: :no_node)
      assert_includes message, "brew install node"
      assert_includes message, "nvm"
    end
  end

  # THE ONE THAT MATTERS. A session that reaches this message must not go and try
  # `npx playwright install`, because on this fleet that cannot work and does not
  # say so — the CDN 400s, a half-extracted browser reads as installed, and the
  # launch dies on a missing dylib. ISS-608 proposed exactly that reinstall as its
  # own remedy, so the message has to close the door explicitly.
  def test_a_machine_without_chrome_is_told_why_playwrights_chromium_is_not_the_answer
    with_machine(chrome: false) do |path:, env:|
      assert_equal :no_chrome, Browse.blocking_reason(path: path, env: env)
      message = Browse.message(reason: :no_chrome)
      assert_includes message, "brew install --cask google-chrome"
      assert_includes message, "400"
      assert_includes message, "playwright install"
    end
  end

  # A missing checkout is reported before a missing browser: there is no point
  # installing Chrome for a tool that is not on the machine.
  def test_a_machine_missing_everything_reports_the_checkout_first
    with_machine(impl: false, node: false, chrome: false) do |path:, env:|
      assert_equal :no_impl, Browse.blocking_reason(path: path, env: env)
    end
  end

  # ---- the channel override ---------------------------------------------------

  # browse.mjs takes BROWSE_CHANNEL, so a machine deliberately pointed at another
  # build has no reason to own Chrome. A guard that refused the run anyway would
  # be blocking something that works, which is strictly worse than the `command
  # not found` this replaces.
  def test_a_non_default_channel_does_not_require_chrome
    with_machine(chrome: false) do |path:, env:|
      assert_nil Browse.blocking_reason(path: path, env: env.merge("BROWSE_CHANNEL" => "msedge"))
    end
  end

  def test_the_default_channel_still_requires_chrome
    with_machine(chrome: false) do |path:, env:|
      assert_equal :no_chrome, Browse.blocking_reason(path: path, env: env.merge("BROWSE_CHANNEL" => "chrome"))
    end
  end

  # ---- the launcher itself ----------------------------------------------------

  # bin/browse holds no policy — it asks lib/ and execs. If it grows a second
  # opinion about what is installed, the two will disagree on some machine and
  # only one of them is tested.
  def test_the_launcher_delegates_rather_than_deciding
    source = File.read(File.expand_path("../bin/browse", __dir__))
    assert_includes source, "Browse.blocking_reason"
    assert_includes source, "Browse.impl_path"
    assert_includes source, "exec("
  end

  def test_the_launcher_is_executable
    assert File.executable?(File.expand_path("../bin/browse", __dir__)),
           "bin/browse must be executable — it is resolved off PATH, not invoked as `ruby bin/browse`"
  end
end
