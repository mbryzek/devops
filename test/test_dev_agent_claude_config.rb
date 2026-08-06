#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::ClaudeConfig — the `~/code/.claude` symlink every Claude Code session
# on a runner resolves its rules, skills and subagents through (ISS-615).
#
# Every assertion here is about a SILENCE. A missing `.claude` produces no error
# anywhere: CLAUDE.md still loads, the session still starts, and it simply never
# sees a rule or a skill. So the tests below prove the two halves that silence
# hides — that the link gets made on a machine that lacks it, and that a machine
# where somebody already put something there is never quietly overwritten.
class TestDevAgentClaudeConfig < Minitest::Test
  include DevTestSupport

  # `code_root` stands in for ~/code: the claude repo is a child of it, and the
  # link this module manages is its sibling. Pointing DEV_AGENT_CLAUDE_REPO at a
  # tmpdir moves BOTH, which is the only reason these tests can run on a machine
  # that has a real ~/code.
  def with_code_root(create_repo: true)
    Dir.mktmpdir do |root|
      code_root = File.join(root, "code")
      repo = File.join(code_root, "claude")
      FileUtils.mkdir_p(create_repo ? repo : code_root)
      original = ENV["DEV_AGENT_CLAUDE_REPO"]
      ENV["DEV_AGENT_CLAUDE_REPO"] = repo
      begin
        yield code_root, repo
      ensure
        ENV["DEV_AGENT_CLAUDE_REPO"] = original
      end
    end
  end

  def link_in(code_root) = File.join(code_root, ".claude")

  def test_the_link_is_created_on_a_machine_that_has_none
    with_code_root do |code_root, repo|
      assert_equal :absent, Agent::ClaudeConfig.state.state

      result = Agent::ClaudeConfig.ensure_link

      assert_equal :linked, result.state
      assert result.ok?
      # realpath on both sides: macOS puts tmpdirs under a symlinked /var.
      assert_equal File.realpath(repo), File.realpath(link_in(code_root))
    end
  end

  # RELATIVE, not absolute. The runners and Mike's machine have different
  # usernames; an absolute link baked in on one is a dangling link on the other,
  # and a dangling link is the failure this module exists to end.
  def test_the_link_is_relative_to_its_own_directory
    with_code_root do |code_root, _repo|
      Agent::ClaudeConfig.ensure_link

      assert_equal "claude", File.readlink(link_in(code_root))
    end
  end

  # The tick calls this every 30 seconds forever, so "already correct" has to be
  # a no-op that reports no change — otherwise the decision log says the machine
  # was repaired twice a minute for the rest of its life.
  def test_a_second_call_is_a_no_op_and_reports_no_change
    with_code_root do |_code_root, _repo|
      assert_equal :linked, Agent::ClaudeConfig.ensure_link.state

      second = Agent::ClaudeConfig.ensure_link

      assert_equal :ok, second.state
      assert second.ok?
      refute second.linked?
    end
  end

  # THE ONE THAT MATTERS MOST. A real `.claude` directory is somebody's
  # deliberate configuration — possibly a second checkout under the dotted name.
  # Unlinking it to "repair" the machine would destroy config this code cannot
  # read and did not create.
  def test_a_real_directory_in_the_way_is_reported_and_never_removed
    with_code_root do |code_root, _repo|
      FileUtils.mkdir_p(File.join(link_in(code_root), "rules"))
      File.write(File.join(link_in(code_root), "rules", "mine.mdc"), "hand written")

      result = Agent::ClaudeConfig.ensure_link

      assert_equal :conflict, result.state
      refute result.ok?
      assert_equal "hand written", File.read(File.join(link_in(code_root), "rules", "mine.mdc"))
      refute File.symlink?(link_in(code_root))
    end
  end

  def test_a_symlink_pointing_elsewhere_is_reported_and_never_repointed
    with_code_root do |code_root, _repo|
      elsewhere = File.join(code_root, "somewhere-else")
      FileUtils.mkdir_p(elsewhere)
      File.symlink(elsewhere, link_in(code_root))

      result = Agent::ClaudeConfig.ensure_link

      assert_equal :conflict, result.state
      assert_equal elsewhere, File.readlink(link_in(code_root))
    end
  end

  # A dangling `.claude` is strictly worse than an absent one: it looks
  # configured to a human reading `ls -la`, and resolves to nothing for a
  # session. With no repo to point at, make nothing.
  def test_no_link_is_created_when_there_is_no_claude_checkout_to_point_at
    with_code_root(create_repo: false) do |code_root, _repo|
      result = Agent::ClaudeConfig.ensure_link

      assert_equal :missing_repo, result.state
      refute result.ok?
      refute File.symlink?(link_in(code_root))
      refute File.exist?(link_in(code_root))
    end
  end

  # `dev agent doctor` reports this machine, so reading it must not change it.
  def test_state_never_writes
    with_code_root do |code_root, _repo|
      assert_equal :absent, Agent::ClaudeConfig.state.state

      refute File.symlink?(link_in(code_root))
      refute File.exist?(link_in(code_root))
    end
  end

  # `remedy` is a literal command for the same reason Toolchain's `install` is:
  # the only question a broken machine asks is what to type.
  def test_every_unfixable_state_says_what_to_type
    with_code_root do |code_root, _repo|
      assert_includes Agent::ClaudeConfig.state.remedy, "ln -s claude #{link_in(code_root)}"
    end

    with_code_root(create_repo: false) do |_code_root, repo|
      assert_includes Agent::ClaudeConfig.ensure_link.remedy, "gh repo clone mbryzek/claude #{repo}"
    end
  end

  # ---- the doctor ----

  def test_the_doctor_reports_an_absent_link_and_says_what_to_type
    with_code_root do |code_root, _repo|
      out = capture_stdout { agent_doctor_claude_config }

      assert_match(/MISS/, out)
      assert_includes out, "ln -s claude #{link_in(code_root)}"
    end
  end

  # A doctor that quietly fixed the machine could never tell you what state you
  # were in when you ran it — and provisioning would keep passing on a box that
  # is only ever healthy because someone ran the doctor.
  def test_the_doctor_reads_without_repairing
    with_code_root do |code_root, _repo|
      capture_stdout { agent_doctor_claude_config }

      refute File.symlink?(link_in(code_root)), "the doctor repaired the machine it was asked to report on"
    end
  end

  def test_the_doctor_reports_a_healthy_machine_as_ok
    with_code_root do |_code_root, _repo|
      Agent::ClaudeConfig.ensure_link

      out = capture_stdout { agent_doctor_claude_config }

      assert_match(/ok\s/, out)
      refute_match(/MISS/, out)
    end
  end
end
