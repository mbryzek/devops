#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/paths'
require 'agent/merge_lane'
require 'agent/workspace'
require 'agent/prompt'

# Moving a pull request branch (ISS-769), and the pair that has to move together.
#
# `agent/instructions.md` §3 tells every session "Never force-push", flat. The
# merge lane's AHEAD invariant means a PR whose base has moved cannot land until
# something brings the base under it — and once the lane merges anything, that is
# the state of every other PR in the repo. So the lane's most frequently returned
# non-terminal verdict named work no session was permitted to perform. It called
# that work `:rebase`, and a rebase of an existing PR branch is a force-push.
#
# The resolution is not a softened rule. It is a NARROWER ACT: GitHub's
# update-branch endpoint merges the base into the head server-side, so nothing is
# rewritten, nothing is pushed from a session, and the endpoint itself has no
# rebase mode and refuses on conflict — it cannot become a force-push or author a
# resolution however it is called.
#
# That only holds while three things agree, which is why this file guards them
# together rather than one at a time:
#
#   the RULE   in `agent/instructions.md` §3, part 1 of every session's prompt.
#              Softening it back to a bare "never" makes the lane's verdict
#              unactionable again; widening it past this one command re-opens
#              exactly what ISS-765 closed.
#   the NAME   the verdict a session reads. `:rebase` described an act it may not
#              perform, which is the whole bug — a name that lies is followed.
#   the ACT    `Agent::MergeLane.update_branch!`, which has to stay a server-side
#              merge. The moment it grows a `--rebase`, a `git push` or a
#              `--force`, the rule above is false and nothing else would notice.
#
# A test over the prose alone passes forever on an implementation that drifted;
# a test over the implementation alone says nothing about what sessions are told.
class TestAgentBranchUpdateRule < Minitest::Test
  include DevTestSupport

  ML = Agent::MergeLane

  # A green, up-to-date PR row, so a test can set `base_status` alone and know
  # that is what the verdict is about.
  def base_pr
    { "number" => 41, "title" => "ISS-700: do a thing", "state" => "OPEN",
      "isDraft" => false, "isCrossRepository" => false, "baseRefName" => "main",
      "headRefOid" => "a" * 40, "mergeStateStatus" => "CLEAN",
      "statusCheckRollup" => [
        { "__typename" => "CheckRun", "name" => "ci", "status" => "COMPLETED",
          "conclusion" => "SUCCESS", "headSha" => "a" * 40 },
      ] }
  end

  # Read per call rather than memoized: minitest inspects `self` on a failure and
  # a 30KB ivar buries the assertion that failed.
  def instructions = File.read(Agent::Paths.instructions_file)

  def not_relaxed_section
    section = instructions[/^## 3\. What is NOT relaxed.*?^## 4\./m]
    refute_nil section, "instructions.md no longer has a §3 / §4 to place the rule between"
    section
  end

  def assert_section_says(pattern, why)
    assert not_relaxed_section.match?(pattern),
           "agent/instructions.md §3: #{why} (looked for #{pattern.inspect})"
  end

  # ---- the rule -------------------------------------------------------------

  def test_the_force_push_prohibition_survives
    assert_section_says(/Never force-push/,
                        "the force-push prohibition is gone. ISS-769 narrowed the ACT the lane asks " \
                        "for; it did not license rewriting branches")
  end

  # The reason travels with the rule, as it does for the devops one. A bare
  # prohibition invites the next session to read it as bureaucracy; "there is no
  # undo" is what makes it obviously correct.
  def test_the_rule_states_why_a_rewritten_branch_is_different
    assert_section_says(/no undo|nothing restores/,
                        "the rule no longer says a rewritten branch cannot be restored, which is the " \
                        "one fact that distinguishes it from a merge (ISS-765)")
  end

  # The single exception, stated as a command rather than as a permission —
  # exactly the shape §3 already uses for `dev agent merge`. A rule that says
  # "never" while a loop does it nightly teaches every session that this file is
  # approximate.
  def test_the_one_sanctioned_act_is_named_as_a_command
    assert_section_says(/dev agent update-branch/,
                        "§3 no longer names the one sanctioned way to move a PR branch, so the lane's " \
                        "`needs_update` verdict is unactionable again")
    assert_section_says(/update-branch/,
                        "§3 must name the endpoint, not just the command — the permission rests on WHICH " \
                        "call it makes")
    assert_section_says(/merge|MERGES/,
                        "§3 must say the sanctioned act merges the base in, which is why it is not a " \
                        "force-push")
  end

  # The exception is bounded on the far side too, or it is not an exception.
  def test_the_rule_closes_the_rebase_variant_of_the_same_command
    assert_section_says(/--rebase/,
                        "`gh pr update-branch --rebase` rewrites the branch. §3 names the merge form as " \
                        "sanctioned, so it has to name the rebase form as not")
  end

  # ---- the name a session reads --------------------------------------------

  def test_no_verdict_tells_a_session_to_rebase
    refute_includes ML::ACTIONS, :rebase,
                    "`:rebase` names a force-push, which agent/instructions.md §3 forbids to every " \
                    "session. That contradiction IS ISS-769 — do not reintroduce the name."
    assert_includes ML::ACTIONS, :update
  end

  def test_the_behind_verdict_points_at_the_sanctioned_command
    v = ML.verdict(base_pr, repo: "mbryzek/platform", base_status: "behind")
    assert_equal :update, v.action
    assert_includes v.message, "dev agent update-branch",
                    "the verdict has to name the command that may perform it, or a session improvises"
    refute_match(/rebase/i, v.message,
                 "the message must not describe the work as a rebase — that is the act §3 forbids")
  end

  # ---- the act --------------------------------------------------------------

  # The load-bearing assertion of this whole file. `update_branch!` is allowed to
  # exist because of WHICH call it makes, so a change to that call is a change to
  # the rule in §3 whether or not anyone edits the prose.
  def test_the_act_is_a_server_side_merge_and_can_never_become_a_push
    seen = nil
    stub_shell(->(cmd, _opts) { seen = cmd; shell_result }) do
      ML.update_branch!("mbryzek/platform", 41, head_sha: "a" * 40)
    end
    joined = seen.join(" ")
    assert_includes joined, "repos/mbryzek/platform/pulls/41/update-branch",
                    "the permission in §3 rests on this being GitHub's server-side update-branch endpoint"
    assert_includes joined, "--method PUT"
    refute_includes joined, "--rebase", "the rebase form rewrites the branch and §3 forbids it"
    refute_includes joined, "push", "a session pushing a PR branch is the act §3 forbids"
    refute_includes joined, "--force"
    refute_includes joined, "git", "there is no local clone in this act, which is why it cannot rewrite"
  end

  # ---- the session's OWN branch (ISS-771) -----------------------------------
  #
  # The other branch the same contradiction lives on, and the one every session
  # hits rather than only the merge loop. CLAUDE.md's when-work-is-done step 4
  # says to rebase onto latest `origin/main` and force-push before merge; §3
  # forbids the force-push flat and outranks it. So the pre-merge update — which
  # exists for a real reason (platform #617 regenerated against a pre-#615
  # snapshot) — was work every session was told to do and forbidden to finish,
  # and both ways out of that were invisible in the artifact.
  #
  # The resolution is the same shape as ISS-769's: not a softer rule, a narrower
  # act. Merging `origin/main` in reaches the identical tree, and squash-merge
  # discards the merge commit and the linear history a rebase would have made
  # alike — so nothing step 4 is for is lost, and the push is an ordinary one.
  #
  # Same three-way agreement, so the same file guards it: the RULE in §3, the
  # PROCEDURE in §6, and the ACT in `Agent::Workspace.resume`, which prepares the
  # checkout a resumed session opens into. That last one is why this cannot be a
  # prose test alone — the executor rebased the branch before handing it over,
  # which left `origin/<branch>` unreachable by any push §3 permits, for review
  # feedback as much as for drift.

  def resuming_section
    text = instructions[/^## 6\. Resuming.*?^## 7\./m]
    refute_nil text, "instructions.md no longer has a §6 / §7 to place the pre-merge procedure between"
    text
  end

  def test_the_rule_reaches_the_branch_the_session_was_assigned
    assert_section_says(/includes the branch you were assigned/i,
                        "§3 no longer says the force-push prohibition covers your OWN branch. Scoping it to " \
                        "other people's branches is ISS-771 option (a), which was rejected: 'mine' is a " \
                        "judgment, and §4 says a retry's checkout can carry commits you did not write")
    assert_section_says(/force-with-lease/,
                        "§3 has to close --force-with-lease by name — it is the flag a session reaches for " \
                        "once it decides the branch is its own, and it does not help here")
  end

  # §6 has to name the act, not merely forbid the other one: a session that is
  # told what it may not do and not what it may do improvises, which is exactly
  # how this file came to describe unperformable work.
  def test_the_pre_merge_update_is_a_merge_and_is_spelled_out
    assert_match(/git merge origin\/main/, resuming_section,
                 "§6 no longer spells out the pre-merge update. The command is the artifact — it is what " \
                 "makes the difference from a rebase concrete rather than a preference (ISS-771)")
    refute_match(%r{git push[^\n]*--force}, resuming_section,
                 "§6 asks for a force-push. That contradiction with §3 IS ISS-771 — §6 may NAME the flag " \
                 "to close it off, but no push it prescribes may carry one")
    refute_match(%r{rebase (onto|origin/main)}, resuming_section,
                 "§6 tells a session to rebase its branch, which it can then only push with a force " \
                 "(ISS-771). Say what to do instead, do not merely forbid it")
  end

  # The whole point is that §3, §6 and CLAUDE.md step 4 end up saying the same
  # thing, which is what ISS-765 and ISS-769 were both about. §6 is where the
  # disagreement with CLAUDE.md is declared, so it has to be declared.
  def test_section_6_says_it_overrides_claude_md_rather_than_silently_differing
    assert_match(/CLAUDE\.md/, resuming_section,
                 "§6 changes what CLAUDE.md step 4 tells a session to do, so it has to say so. An " \
                 "undeclared difference is the state ISS-771 was filed about")
  end

  # ---- the act the executor performs on that branch -------------------------

  # THE load-bearing assertion of the ISS-771 half. A rebase here rewrites every
  # commit on the branch, so the checkout a resumed session opens into has
  # diverged from `origin/<branch>` and its ONLY route back to the PR is a
  # force-push — for a one-line review fix as much as for drift. The prose in §6
  # is true only while this stays a merge.
  def test_the_resumed_checkout_is_merged_not_rebased
    calls = resume_calls
    assert_includes calls, "git merge --no-edit origin/main",
                    "the executor must MERGE main under a resumed branch. A rebase leaves the session " \
                    "unable to push at all without the force-push §3 forbids (ISS-771)"
    refute(calls.any? { |c| c.include?("rebase") },
           "a rebase of the resumed branch is the act that made §6 unperformable: #{calls.inspect}")
    refute(calls.any? { |c| c.include?("--force") || c.include?("push") },
           "the executor never pushes a session's branch: #{calls.inspect}")
  end

  # The session is told what state its checkout is in, and a wrong answer here is
  # worse than none: "rebased onto origin/main" is precisely what would send it
  # looking for a force-push.
  def test_the_resume_prompt_does_not_tell_the_session_its_branch_was_rebased
    text = Agent::Prompt.assignment(issue: { "number" => 771, "title" => "t", "category" => "improvement" },
                                    slug: "i771", workspace: "/ws/i771", resume_repo: "mbryzek/devops")
    assert_match(/MERGED in/, text,
                 "the resume block must say the branch was merged, so the session knows an ordinary push " \
                 "reaches the PR")
    refute_match(/rebased onto/, text,
                 "the resume block claimed the branch was rebased, which is both false now and the reason " \
                 "a session would reach for a force-push (ISS-771)")
  end

  # Every git/gh call `resume` makes, with the network and the filesystem stubbed
  # out. Mirrors `test_agent_workspace_repos.rb`, which asserts the sibling path's
  # command sequence for the same reason: the sequence IS the behaviour here.
  def resume_calls
    seen = []
    tmp = Dir.mktmpdir("i771")
    Agent::Workspace.singleton_class.send(:alias_method, :run_without_stub, :run)
    Agent::Workspace.singleton_class.send(:alias_method, :create_without_stub, :create)
    Agent::Workspace.define_singleton_method(:run) { |cmd, chdir:| seen << cmd.join(" ") && true }
    Agent::Workspace.define_singleton_method(:create) do |slug|
      File.join(tmp, slug).tap { |d| FileUtils.mkdir_p(d) }
    end
    stub_singleton(Agent::Github, :search_open_pr, ->(_branch) { { "repository" => "mbryzek/devops" } }) do
      Agent::Workspace.resume("i771")
    end
    seen
  ensure
    Agent::Workspace.singleton_class.send(:alias_method, :run, :run_without_stub)
    Agent::Workspace.singleton_class.send(:alias_method, :create, :create_without_stub)
    FileUtils.remove_entry(tmp) if tmp && File.directory?(tmp)
  end
end
