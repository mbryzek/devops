#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_helper'
require 'agent/paths'
require 'agent/merge_lane'

# The autonomous-session push guard over `~/code/claude` (ISS-1061).
#
# ~/code/claude is the standing exception to "never push to main", which makes it
# the ONE place in this system where a write by an unattended session takes effect
# with nobody looking — every other repo's writes land behind a human merge. The
# guard exists for that asymmetry, and ISS-1061 moved where it draws its line:
#
#   BEFORE  only `plans/` could be pushed at all, on any ref.
#   NOW     the four DOCUMENT directories go straight to main; everything else —
#           CLAUDE.md, rules/, skills/, agents/, tools/, settings*.json — is
#           allowed on a BRANCH, where it can only land as a PR a human merges.
#
# The widening is not a relaxation of the threat model, and the tests below are
# arranged to prove that rather than to assert it. What the guard protects against
# is a prompt-injected session persisting itself into instructions every future
# session loads — and a pull request removes that exposure completely, because
# `claude` is in neither Agent::MergeLane::LANE_REPOS nor the `ci` enrolment that
# actually makes a repo mergeable, so no merge loop can reach it.
#
# Like test_agent_devops_merge_rule.rb, this guards a PAIR:
#
#   the FACT  is `agent/githooks/pre-push`, exercised here through real `git push`
#             invocations against a throwaway repo. Not by reading the script: the
#             failure mode that matters is a shell bug that waves a push through,
#             and only running it can find one. `git diff-tree` silently listing
#             nothing for a parentless commit was exactly that, and is case 1.
#   the RULE  is `agent/instructions.md` §3, which is part 1 of every session's
#             prompt. A guard the prompt describes wrongly produces sessions that
#             route around it — ISS-1061 exists because a session was told a doc
#             fix was impossible when the real answer was "not on main".
#
# A test over the script alone would pass while every session was told the wrong
# rule; a test over the prose alone proves nothing about what git does.
class TestAgentClaudePushGuard < Minitest::Test
  include DevTestSupport

  # A throwaway repo standing in for ~/code/claude, wired exactly as `dev agent
  # tick` wires a real session (Agent::Tick#child_env): core.hooksPath through
  # GIT_CONFIG_*, and DEV_AGENT_CLAUDE_REPO naming the guarded repo. Pointing the
  # latter at a tmpdir is the only reason this can run on a machine that has a
  # real ~/code/claude — without it the hook would compare against the developer's
  # own checkout and exit 0 before testing anything.
  def with_claude_repo
    Dir.mktmpdir do |root|
      work = File.join(root, "work")
      remote = File.join(root, "remote")
      run!("git", "init", "--bare", "-q", remote)
      run!("git", "init", "-q", work)
      run!("git", "-C", work, "config", "user.email", "t@example.com")
      run!("git", "-C", work, "config", "user.name", "t")
      run!("git", "-C", work, "remote", "add", "origin", remote)
      yield work
    end
  end

  def run!(*cmd, env: {})
    out = IO.popen(env, cmd, err: [:child, :out], &:read)
    raise "command failed: #{cmd.join(' ')}\n#{out}" unless $?.success?
    out
  end

  # The environment a session's git runs under. Built from Agent::Paths so the
  # test follows the hook if it ever moves, rather than pinning a literal path
  # that would keep passing against a file nothing installs.
  def session_env(work)
    {
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "core.hooksPath",
      "GIT_CONFIG_VALUE_0" => Agent::Paths.githooks_dir,
      "DEV_AGENT_CLAUDE_REPO" => work,
    }
  end

  def commit(work, paths)
    paths.each do |path, body|
      full = File.join(work, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
    run!("git", "-C", work, "add", "-A")
    run!("git", "-C", work, "commit", "-q", "-m", "c")
  end

  # [allowed?, combined output]. The push is the assertion: a guard is what git
  # actually did, not what the script says it would do.
  def push(work, ref: "main")
    out = IO.popen(session_env(work), ["git", "-C", work, "push", "origin", "HEAD:#{ref}"],
                   err: [:child, :out], &:read)
    [$?.success?, out]
  end

  # ---- the four document directories reach main ----

  def test_an_initial_commit_of_documents_reaches_main
    with_claude_repo do |work|
      commit(work, "plans/note.md" => "a")
      allowed, out = push(work)
      assert allowed, "a documents-only initial commit must reach main:\n#{out}"
    end
  end

  # The regression test for the `--root` bug found while writing this file, and it
  # has to assert a REFUSAL to be worth anything. `git diff-tree` prints nothing
  # for a parentless commit, so without `--root` the guard saw an empty file list
  # on an initial push and waved the whole thing through — CLAUDE.md included.
  #
  # The asymmetry is the point and cost a pass here already: the sibling test
  # above, which pushes documents and asserts "allowed", goes green under that bug
  # too, because "allowed" is exactly what a guard that inspected nothing returns.
  # Only a case whose correct answer is "refused" can tell the two apart.
  def test_an_initial_commit_cannot_smuggle_an_instruction_past_the_guard
    with_claude_repo do |work|
      commit(work, "CLAUDE.md" => "poisoned", "plans/note.md" => "a")
      allowed, out = push(work)
      refute allowed, "an initial commit is still a commit — CLAUDE.md must not ride in on it:\n#{out}"
      assert_includes out, "CLAUDE.md"
    end
  end

  def test_every_document_directory_reaches_main
    with_claude_repo do |work|
      commit(work, "plans/seed.md" => "a")
      assert push(work).first
      # The four together, which is also the ISS-1049 case: product/playbook.md is
      # the file a session did all the work on and then could not apply.
      commit(work, "plans/n.md" => "a", "product/playbook.md" => "b",
                   "design/mock.html" => "c", "docs/guide.md" => "d")
      allowed, out = push(work)
      assert allowed, "the document directories must reach main:\n#{out}"
    end
  end

  # A prefix is not a segment. `plansomething/` shares five characters with the
  # allowance and none of its meaning.
  def test_a_directory_that_merely_starts_with_a_document_name_is_refused
    with_claude_repo do |work|
      commit(work, "plans/seed.md" => "a")
      assert push(work).first
      commit(work, "plansomething/x.md" => "b")
      allowed, out = push(work)
      refute allowed, "`plansomething/` is not `plans/`"
      assert_includes out, "plansomething/x.md"
    end
  end

  # ---- the instruction surface does not reach main ----

  # Each of these is a file every future session loads and obeys, which is the
  # entire threat model: settings.local.json is the sharpest of them, because it
  # carries the permission allowlist and hook definitions — persistence there needs
  # nobody to be persuaded of anything.
  {
    "CLAUDE.md" => "CLAUDE.md",
    "a rule" => "rules/scala.general.mdc",
    "a skill" => "skills/repo-map/SKILL.md",
    "a subagent definition" => "agents/code-reviewer.md",
    "executable tooling" => "tools/browse/index.js",
    "the settings file" => "settings.local.json",
  }.each do |label, path|
    define_method("test_#{label.tr(' .', '__')}_is_refused_on_main") do
      with_claude_repo do |work|
        commit(work, "plans/seed.md" => "a")
        assert push(work).first
        commit(work, path => "poisoned")
        allowed, out = push(work)
        refute allowed, "#{label} (#{path}) must not reach main unreviewed:\n#{out}"
        assert_includes out, path
        assert_includes out, "REFUSED"
      end
    end
  end

  # One document alongside one instruction is still refused. A guard that passed
  # a mixed commit would be trivially defeated by adding a plans/ file to it.
  def test_a_document_does_not_carry_an_instruction_through
    with_claude_repo do |work|
      commit(work, "plans/seed.md" => "a")
      assert push(work).first
      commit(work, "plans/cover.md" => "a", "rules/x.mdc" => "b")
      allowed, out = push(work)
      refute allowed, "a mixed commit must be refused"
      assert_includes out, "rules/x.mdc"
      refute_includes out.split("Offending paths:").last, "plans/cover.md"
    end
  end

  # ---- the same change is allowed on a branch, which is the PR route ----

  # This is the half that makes the widening safe rather than merely permissive.
  # The rule is about REVIEW, not about paths: a branch is inert — nothing loads
  # it — and it can only reach main through a pull request Mike merges.
  def test_the_instruction_surface_is_allowed_on_a_branch
    with_claude_repo do |work|
      commit(work, "plans/seed.md" => "a")
      assert push(work).first
      commit(work, "CLAUDE.md" => "x", "rules/x.mdc" => "y", "settings.local.json" => "{}")
      allowed, out = push(work, ref: "i1061")
      assert allowed, "instruction changes must be pushable on a branch, as a PR:\n#{out}"
    end
  end

  # The refusal has to name the route, because a refusal that only says no is what
  # produced ISS-1061: the session concluded the write was impossible, handed four
  # commands to a human, and the fix waited on a paste.
  def test_the_refusal_names_the_pull_request_route
    with_claude_repo do |work|
      commit(work, "plans/seed.md" => "a")
      assert push(work).first
      commit(work, "rules/x.mdc" => "b")
      _allowed, out = push(work)
      assert_includes out, "gh pr create"
      assert_match(/NOT off limits/, out)
    end
  end

  # ---- every other repo passes through untouched ----

  # The hook is injected globally through core.hooksPath, so it runs on every push
  # a session makes in every repo. It must never be the reason a platform push
  # fails — a guard with collateral is one somebody switches off.
  def test_another_repo_is_not_guarded_at_all
    with_claude_repo do |work|
      Dir.mktmpdir do |other_root|
        other = File.join(other_root, "platform")
        remote = File.join(other_root, "remote")
        run!("git", "init", "--bare", "-q", remote)
        run!("git", "init", "-q", other)
        run!("git", "-C", other, "config", "user.email", "t@example.com")
        run!("git", "-C", other, "config", "user.name", "t")
        run!("git", "-C", other, "remote", "add", "origin", remote)
        FileUtils.mkdir_p(File.join(other, "conf"))
        File.write(File.join(other, "CLAUDE.md"), "x")
        File.write(File.join(other, "conf", "routes"), "y")
        run!("git", "-C", other, "add", "-A")
        run!("git", "-C", other, "commit", "-q", "-m", "c")
        # DEV_AGENT_CLAUDE_REPO still points at the guarded repo; this push is
        # from a different toplevel and must be none of the hook's business.
        out = IO.popen(session_env(work), ["git", "-C", other, "push", "origin", "HEAD:main"],
                       err: [:child, :out], &:read)
        assert $?.success?, "a push in another repo must pass through untouched:\n#{out}"
      end
    end
  end

  # ---- the rule, as every session is told it ----

  def not_relaxed_section
    section = File.read(Agent::Paths.instructions_file)[/^## 3\. What is NOT relaxed.*?^## 4\./m]
    refute_nil section, "instructions.md no longer has a §3 / §4 to place the rule between"
    section
  end

  def assert_section_says(pattern, why)
    assert not_relaxed_section.match?(pattern), "agent/instructions.md §3: #{why} (looked for #{pattern.inspect})"
  end

  def test_the_rule_names_every_directory_the_hook_permits
    %w[plans product design docs].each do |dir|
      assert_section_says(/`#{dir}\/`/, "#{dir}/ is pushable but §3 does not say so, so no session will use it")
    end
  end

  def test_the_rule_states_the_pull_request_route
    assert_section_says(/pull request/,
                        "§3 must say the instruction surface is reachable by PR — a session told only " \
                        "'refused' files a handoff instead, which is ISS-1061")
    assert_section_says(/not off limits/i,
                        "§3 must say the instruction surface is not forbidden, only unreviewable by push")
  end

  # The property the whole guard rests on. A session can PROPOSE a change to what
  # sessions may write; it cannot make one, because the hook lives in devops and
  # every devops PR is classified irreversible and left for a human.
  def test_the_guard_is_not_self_amendable
    assert_includes Agent::Paths.githooks_dir, Agent::Paths.devops_repo,
                    "the hook must live in devops — inside the repo it guards, a push could rewrite it"
    assert_includes Agent::MergeLane::SELF_DEPLOYING_REPOS, "devops",
                    "devops must stay unmergeable by an agent, or the guard becomes self-amendable"
    refute_includes Agent::MergeLane::LANE_REPOS, "claude",
                    "claude must stay out of the merge lane — a PR there is the human review the " \
                    "branch allowance depends on, and an auto-merged one would be no review at all"
  end
end
