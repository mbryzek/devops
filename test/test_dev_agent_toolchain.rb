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
    stub_singleton(Open3, :capture2, ->(*_args) { raise Errno::ENOENT }) do
      assert_equal "/sentinel/bin", T.agent_path(env: { "PATH" => "/sentinel/bin" })
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

  # ---- the registry cannot drift from the producers it names ------------------

  # The whole point of naming producer keys on a tool is that a filed issue can
  # say "the depsguard producer has never run" rather than "a binary is absent".
  # A key that no longer exists in agent/producers.yml turns that sentence into a
  # lie, and nothing else in the system would notice — same reasoning as
  # test_agent_cron_migration.rb asserting children.names == ApiLint::REPOS.
  def test_every_producer_named_by_a_tool_exists_in_the_registry
    keys = Agent::Producers.load.fetch(:producers).map(&:key)
    T::TOOLS.each do |t|
      t.producers.each do |key|
        assert_includes keys, key, "#{t.name} names producer `#{key}`, which is not in agent/producers.yml"
      end
    end
  end

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

  def test_every_tool_carries_an_install_command_and_a_reason
    T::TOOLS.each do |t|
      refute_empty t.install.to_s, "#{t.name}: no install command — the one question a broken box asks"
      refute_empty t.required_by.to_s, "#{t.name}: no required_by"
    end
  end
end
