#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/paths'
require 'agent/merge_lane'

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
end
