#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-562, executor half: the repos an issue names are cloned into the attempt's
# workspace with the attempt's branch already created, and the prompt says so.
#
# Every git/gh call is stubbed — nothing here clones anything. What is asserted is
# the exact COMMAND SEQUENCE, because that is where this can go silently wrong:
#
#   - `checkout -B` instead of `checkout -b` on a branch that already exists would
#     reset an earlier attempt's commits to origin/main. That is the one
#     irreversible thing this code path could do, and no test after the fact could
#     tell it had happened.
#   - a repo that fails to clone must be ABSENT from the prompt rather than
#     announced, or the session is told to work in a checkout that is not there.
class TestAgentWorkspaceRepos < Minitest::Test
  include DevTestSupport

  def setup
    @calls = []
    @fail = []
    @existing_branch = false
    @tmp = Dir.mktmpdir("i562")
    test = self
    Agent::Workspace.singleton_class.send(:alias_method, :run_without_stub, :run)
    Agent::Workspace.singleton_class.send(:alias_method, :create_without_stub, :create)
    Agent::Workspace.define_singleton_method(:run) { |cmd, chdir:| test.record(cmd) }
    Agent::Workspace.define_singleton_method(:create) do |slug|
      dir = File.join(test.tmp, slug)
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  def teardown
    Agent::Workspace.singleton_class.send(:alias_method, :run, :run_without_stub)
    Agent::Workspace.singleton_class.send(:alias_method, :create, :create_without_stub)
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  attr_reader :tmp

  # Stubbed `run`: records the command, then answers the way the real git would.
  def record(cmd)
    @calls << cmd
    return false if @fail.any? { |f| cmd.join(" ").include?(f) }
    # `rev-parse --verify` answers "does this branch already exist here".
    return @existing_branch if cmd[1] == "rev-parse"
    true
  end

  def git_calls = @calls.map { |c| c.join(" ") }

  def test_each_named_repo_is_cloned_and_branched_off_latest_origin_main
    prepared = Agent::Workspace.prepare("i562_jd8", %w[platform devops], branch: "i562_jd8")

    assert_equal %w[platform devops], prepared.repos
    assert_empty prepared.continued, "a branch created off origin/main is not a continuation"
    assert_includes git_calls, "gh repo clone mbryzek/platform #{@tmp}/i562_jd8/platform"
    assert_includes git_calls, "gh repo clone mbryzek/devops #{@tmp}/i562_jd8/devops"
    assert_equal 2, git_calls.count("git fetch origin")
    assert_equal 2, git_calls.count("git checkout -b i562_jd8 origin/main")
  end

  # The destructive case. A branch that is already here belongs to an earlier
  # attempt and is in a PR; it is checked out, never reset.
  def test_an_existing_branch_is_checked_out_not_reset
    @existing_branch = true
    prepared = Agent::Workspace.prepare("i562_jd8", %w[platform], branch: "i562_jd8")

    assert_equal %w[platform], prepared.continued,
                 "a derived branch puts this on the ordinary retry path, so it must be REPORTED (ISS-767)"
    assert_includes git_calls, "git checkout i562_jd8"
    refute_includes git_calls, "git checkout -b i562_jd8 origin/main"
    refute(git_calls.any? { |c| c.include?("checkout -B") }, "never reset an existing branch")
  end

  # Best-effort, and the report has to match reality: the repo that would not
  # clone is simply not in the returned list, so the prompt never claims a
  # checkout that does not exist.
  def test_a_repo_that_will_not_clone_is_skipped_rather_than_failing_the_attempt
    @fail << "clone mbryzek/devops"
    assert_equal %w[platform], Agent::Workspace.prepare("i562_jd8", %w[platform devops], branch: "i562_jd8").repos
  end

  # The resume path has already cloned this repo and checked out the EXISTING
  # branch on it. Re-preparing it is the one case that could reach the branch
  # again, so it is skipped outright.
  def test_the_resumed_repo_is_left_alone
    assert_equal %w[devops],
                 Agent::Workspace.prepare("i562_jd8", %w[platform devops], branch: "i562_jd8",
                                                                          already_prepared: "mbryzek/platform").repos
    refute(git_calls.any? { |c| c.include?("mbryzek/platform") })
  end

  def test_blank_and_duplicate_names_are_ignored
    assert_empty Agent::Workspace.prepare("i562_jd8", ["", "  ", nil], branch: "i562_jd8").repos
    assert_empty Agent::Workspace.prepare("i562_jd8", nil, branch: "i562_jd8").repos
    assert_equal %w[platform],
                 Agent::Workspace.prepare("i562_jd8", ["platform", " platform "], branch: "i562_jd8").repos
  end

  # ---- the prompt ----

  def issue = { "number" => "562", "title" => "the flag does not exist", "category" => "bug", "body" => "b" }

  def assignment(prepared, continued: [])
    Agent::Prompt.assignment(issue: issue, slug: "i562_jd8", workspace: "/ws/i562_jd8", prepared_repos: prepared,
                             continued_repos: continued)
  end

  def test_the_prompt_names_the_prepared_checkouts_instead_of_telling_the_session_to_clone
    text = assignment(%w[platform devops])
    assert_match(/already cloned in your workspace/, text)
    assert_match(/`platform`, `devops`/, text)
    refute_match(/Your workspace is empty/, text)
  end

  def test_the_prompt_falls_back_to_clone_it_yourself_when_nothing_was_prepared
    text = assignment([])
    assert_match(/Your workspace is empty/, text)
    refute_match(/already cloned/, text)
  end

  # ISS-767: the branch is derived from the issue, so a retry opens into a
  # checkout carrying commits it did not write. Told nothing, the session reads
  # "off the latest origin/main" above and its two guesses are both wrong — a
  # second PR on work that already has one, or a rebase over a predecessor's diff.
  def test_a_branch_that_already_existed_is_named_in_the_prompt
    text = assignment(%w[platform devops], continued: %w[platform])
    assert_match(/`i562_jd8` ALREADY EXISTED/, text)
    assert_match(/gh pr list --head i562_jd8 --state all/, text)
    refute_match(/`devops`.*ALREADY EXISTED/m, text.lines.grep(/ALREADY EXISTED/).join)
  end

  # The ordinary first attempt says nothing about it — a warning on every claim
  # is a warning nobody reads.
  def test_a_fresh_branch_says_nothing_about_continuing
    refute_match(/ALREADY EXISTED/, assignment(%w[platform devops]))
  end
end
