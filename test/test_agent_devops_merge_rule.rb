#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/paths'

# devops is never auto-merged (ISS-660), and the rule and the fact it rests on
# have to move together.
#
# The `pr_auto_merge` loop is allowed to exist because merging and shipping are
# two acts with a human between them: a merged PR sits on `main` until Mike
# deploys, so a revert PR opened in the meantime fully undoes it. That premise is
# global in the playbook's prose and false in exactly one repo — this one. Phase
# A of every tick fast-forwards `~/code/devops`, 30 seconds apart, so a devops
# merge is a fleet-wide deploy nobody approved, on the code that runs the fleet.
#
# So this file guards a pair, not a sentence:
#
#   the RULE   lives in `agent/instructions.md` §3, which is part 1 of every
#              session's prompt (Agent::Prompt.build) — deliberately not in the
#              pr-auto-merge playbook, because a playbook reaches one session and
#              the next loop somebody writes would inherit nothing. A playbook is
#              also a platform row this suite cannot read, which is the same
#              reason ISS-526 cost test_agent_close_out_contract.rb its
#              one-home guard.
#   the FACT   lives in `Agent::Checkout` and the launchd plist. If the fleet
#              self-update is ever removed or slowed to a human-scale cadence,
#              the premise changes and the rule deserves re-reading rather than
#              silently outliving its reason.
#
# A test over the rule alone would pass forever on a stale justification; a test
# over the fact alone says nothing about the merge loop. Both, together.
class TestAgentDevopsMergeRule < Minitest::Test
  # Read per call rather than memoized into an ivar: minitest inspects `self` on
  # a failure, and a 10KB ivar buries the assertion that failed.
  def instructions
    File.read(Agent::Paths.instructions_file)
  end

  def not_relaxed_section
    section = instructions[/^## 3\. What is NOT relaxed.*?^## 4\./m]
    refute_nil section, "instructions.md no longer has a §3 / §4 to place the rule between"
    section
  end

  # Asserts on a boolean rather than with assert_match, which prints the whole
  # haystack: §3 is 2KB of prose, and a failure that buries its own message under
  # the section it was reading is a failure nobody reads.
  def assert_section_says(pattern, why)
    assert not_relaxed_section.match?(pattern), "agent/instructions.md §3: #{why} (looked for #{pattern.inspect})"
  end

  def test_the_rule_is_in_the_not_relaxed_section
    assert_section_says(/Never merge a `devops` pull request/,
                        "the devops merge prohibition is gone from the not-relaxed section")
  end

  # §3 is "what is NOT relaxed" — safety rules, as opposed to the review gates §2
  # converts into PR sections. A devops merge cannot be reviewed after the fact
  # because it has already shipped to every runner, so this belongs on the side
  # of the file where no artifact substitutes for not doing it.
  def test_the_rule_is_stated_as_absolute
    assert_section_says(/under any playbook or workflow/,
                        "the rule must bind every workflow, not just today's pr_auto_merge loop")
  end

  # The reason travels with the rule. A bare prohibition invites the next session
  # to read it as bureaucracy and reason its way around it; the mechanism is what
  # makes it obviously correct.
  def test_the_rule_states_why
    assert_section_says(/Merging here IS deploying/, "the rule no longer says why merging devops ships it")
    assert_section_says(/fast-forwards/, "the rule no longer names the fleet self-update as the mechanism")
    assert_section_says(/does not merge one/,
                        "the rule must say `gh pr revert` OPENS a revert PR rather than merging one — " \
                        "an undo that is a human's next step is not a rollback")
  end

  # The general prohibition the devops rule is a special case of, and its single
  # exception. Stating "never merge a PR" flat while a loop merges PRs nightly
  # teaches every session that this file's rules are approximate.
  def test_the_general_merge_rule_names_its_one_exception
    assert_section_says(/Never merge a pull request/, "the general merge prohibition is gone")
    assert_section_says(/pr-auto-merge/, "the one exception must name the playbook it belongs to")
    assert_section_says(/auto_approved/,
                        "the exception is the ledger's answer, not the loop's judgment — say so")
  end

  # ---- the rule, enforced in code -------------------------------------------

  # The third home, added with the merge lane (ISS-754). Until it existed the
  # rule had nowhere to live but prose, and prose reaches whoever reads it: the
  # `pr-auto-merge` playbook accumulated its skip list one near-miss at a time
  # (ISS-660, ISS-663) precisely because nothing could enforce one.
  #
  # Asserted from THIS file rather than only from test_agent_merge_lane.rb so
  # that the rule and its enforcement are guarded as a pair, exactly as the rule
  # and its justification are below. A lane that quietly dropped devops from
  # SELF_DEPLOYING_REPOS would still pass its own suite's other 45 tests.
  def test_the_lane_refuses_the_repo_the_rule_names
    require "agent/merge_lane"
    assert_includes Agent::MergeLane::SELF_DEPLOYING_REPOS, "devops",
                    "agent/instructions.md §3 forbids merging a devops PR under any workflow. " \
                    "Agent::MergeLane is the workflow that merges, so it has to know."
    assert_raises(ArgumentError, "the lane must refuse a devops merge even when asked directly") do
      Agent::MergeLane.merge!("mbryzek/devops", 1, head_sha: "a" * 40)
    end
  end

  # ---- the fact the rule rests on -------------------------------------------

  def test_the_fleet_still_fast_forwards_itself_on_every_tick
    checkout = File.read(File.join(Agent::Paths.devops_repo, "lib", "agent", "checkout.rb"))
    assert_match(/--ff-only/, checkout,
                 "Agent::Checkout no longer fast-forwards this checkout. The devops merge rule in " \
                 "agent/instructions.md §3 exists BECAUSE it does — re-read the rule before removing this.")
    assert_match(/\borigin\b.*\bmain\b|\bmain\b/, checkout)
  end

  # The cadence is the other half of "before anyone could look at it". A tick that
  # fired daily would still make a merge a deploy, but it would no longer make it
  # one that lands inside a minute.
  def test_the_tick_fires_on_a_machine_cadence
    plist = File.read(File.join(Agent::Paths.devops_repo, "launchd", "com.bryzek.dev-agent.plist"))
    interval = plist[%r{<key>StartInterval</key>\s*<integer>(\d+)</integer>}m, 1]
    refute_nil interval, "the agent plist no longer declares a StartInterval"
    assert_operator interval.to_i, :<=, 300,
                    "the tick now fires every #{interval}s. agent/instructions.md §3 tells sessions a devops " \
                    "merge is fleet-wide within 30 seconds; fix the prose or reconsider the rule."
  end
end
