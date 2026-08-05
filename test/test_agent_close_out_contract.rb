#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The close-out contract (ISS-507): before a session closes out, anything it
# WORKED AROUND rather than fixed gets filed.
#
# The contract is prose, so what is testable about it is the two properties that
# make prose survive — and both have already failed here once:
#
#   1. It has exactly ONE home. The per-producer close-out sections are
#      copy-pasted between playbooks, so a contract added to each of them is a
#      contract the NEXT playbook will not have. That is ISS-360's shape
#      literally: a producer ported without its playbook silently did generic
#      triage for a week. `agent/instructions.md` is part 1 of every session's
#      prompt (Agent::Prompt.build), producer-filed or not, so a body needs to
#      say nothing at all.
#
#      The GUARD for that property is gone from this file, and knowingly: it read
#      `agent/bodies/*.md`, and ISS-526 moved the playbooks into the platform as
#      copy-on-write rows. Re-homing it means asserting over
#      `agent.agent_producer_playbooks`, which is platform-side work and not this
#      branch's. Property 2 below is unaffected -- it only reads instructions.md.
#
#   2. Every command it names EXISTS. An instruction that cannot be executed as
#      written is the exact thing the contract exists to surface (ISS-503 —
#      four playbooks told sessions to write a path that does not exist on the
#      runner). The contract naming a command that was later renamed would be
#      that failure, in the file that defines the failure.
class TestAgentCloseOutContract < Minitest::Test
  include DevTestSupport

  HEADING = "### Before you close out: file what you WORKED AROUND".freeze
  COMMAND = "dev issues workaround".freeze

  # The contract's other half (ISS-563): a step the session could not take AT ALL,
  # as opposed to one it routed around. Same two properties, same reasons.
  HANDOFF_HEADING = "### Before you close out: hand over what only a HUMAN can run".freeze
  HANDOFF_COMMAND = "dev issues handoff".freeze

  # Read per call rather than memoized into an ivar: minitest inspects `self` on
  # a failure, and a 10KB ivar buries the assertion that failed.
  def instructions
    File.read(Agent::Paths.instructions_file)
  end

  def test_the_contract_is_in_the_standing_instructions
    assert_includes instructions, HEADING
  end

  # Inside §1 ("How this ends"), not appended somewhere later: it applies to all
  # four outcomes in that section's table, including `needs_input` and the
  # nothing-to-do path, neither of which opens a PR.
  def test_the_contract_lives_in_the_close_out_section
    section_one = instructions[/^## 1\. How this ends.*?^## 2\./m]
    refute_nil section_one, "instructions.md no longer has a §1 / §2 to place the contract between"
    assert_includes section_one, HEADING
  end

  # The anti-quota sentence, which the playbooks already carry for their own
  # reviews. Without it the contract reads as a filing target, the queue fills
  # with non-findings, and the signal that made ISS-474 worth filing is buried.
  def test_the_contract_says_filing_nothing_is_the_normal_case
    assert_match(/manufacturing a finding is worse than silence/, instructions)
    assert_match(/Closing out having filed nothing is the NORMAL case/, instructions)
  end

  # The bounded trigger list, verbatim in spirit: four checkable conditions, not
  # "anything that could be better".
  def test_the_contract_states_the_full_trigger_list
    [
      /could not be executed as written/,
      /substitute data source, weaker than the one specified/,
      /crossed a stated guardrail, even if you reverted it/,
      /precondition the assignment assumed was not true on this runner/,
    ].each { |pattern| assert_match(pattern, instructions) }
  end

  def test_the_command_the_contract_names_exists
    assert_includes instructions, COMMAND
    assert_includes SUBCOMMANDS.fetch("issues"), "workaround"
    assert INVOCATIONS.key?("issues workaround")
    # `dev`'s command functions land as private methods on Object, so respond_to?
    # is false for all of them.
    assert Object.private_method_defined?(:cmd_issues_workaround),
           "instructions.md names `#{COMMAND}` but bin/dev has no cmd_issues_workaround"
  end

  # Property 2 of this file's own preamble, generalised past the one contract: EVERY
  # `dev issues <sub>` the standing instructions name has to be a real subcommand.
  # These instructions are part 1 of every session's prompt, so a command that does
  # not exist is not a typo, it is an instruction no session can execute — the exact
  # thing the close-out contract exists to surface. ISS-536 added `dev issues fix`
  # here as the non-destructive way to record a second PR, and a session that cannot
  # run it falls back to the write that un-verified ten issues.
  def test_every_issues_subcommand_the_instructions_name_exists
    named = instructions.scan(/dev issues ([a-z-]+)/).flatten.uniq
    refute_empty named, "the instructions name no issues subcommand — the guard would pass vacuously"
    unknown = named.reject { |sub| SUBCOMMANDS.fetch("issues").include?(sub) }
    assert_empty unknown, "agent/instructions.md names issues subcommand(s) bin/dev does not have"
  end

  # Each flag the contract tells a session to pass, against the command's own
  # invocation line. A flag renamed on one side and not the other leaves every
  # session running a command that exits on arg validation.
  def test_every_flag_the_contract_names_is_a_real_flag
    invocation = usage_for("issues workaround")
    %w[--from --key --title --body].each do |flag|
      assert_includes instructions, flag
      assert_includes invocation, flag
    end
  end

  # ---- the handoff half (ISS-563) -------------------------------------------

  def test_the_handoff_contract_lives_in_the_close_out_section
    section_one = instructions[/^## 1\. How this ends.*?^## 2\./m]
    refute_nil section_one, "instructions.md no longer has a §1 / §2 to place the contract between"
    assert_includes section_one, HANDOFF_HEADING
  end

  def test_the_handoff_command_exists
    assert_includes instructions, HANDOFF_COMMAND
    assert_includes SUBCOMMANDS.fetch("issues"), "handoff"
    assert INVOCATIONS.key?("issues handoff")
    assert Object.private_method_defined?(:cmd_issues_handoff),
           "instructions.md names `#{HANDOFF_COMMAND}` but bin/dev has no cmd_issues_handoff"
  end

  def test_every_flag_the_handoff_contract_names_is_a_real_flag
    invocation = usage_for("issues handoff")
    %w[--from --key --title --body --command --url].each do |flag|
      assert_includes invocation, flag
    end
  end

  # `--command` is the whole difference between this and a close-out comment, and
  # a close-out comment is what left two openclaw crons firing for a day. A
  # contract that shows the flag but not what belongs in it invites prose.
  def test_the_handoff_contract_shows_the_commands_as_the_artifact
    assert_match(/`--command` is the artifact/, instructions)
    assert_match(/the exact line to paste/, instructions)
  end

  # The same anti-quota sentence the workaround half carries, for the opposite
  # failure: a handoff is cheap to file and expensive to receive, so an agent that
  # reads this as an escape hatch costs Mike a queue item per avoided task.
  def test_the_handoff_contract_says_it_is_not_an_escape_hatch
    assert_match(/not an escape hatch for work you could do/i, instructions)
    assert_match(/whether \*any\* session on \*any\* runner could run the command/, instructions)
  end

  # Why `needs_input` rather than `open` IS the fix — stated where a session
  # reads it, because a session that files a handoff at `open` with `workaround`
  # has reproduced ISS-563 exactly.
  def test_the_handoff_contract_says_why_it_is_not_claimable
    assert_match(/`dev issues claim` never offers `needs_input`/, instructions)
  end

  # The one-home guard (property 1) is deliberately absent for this half too, and
  # for the reason the preamble gives: ISS-526 moved the playbooks into the
  # platform, so there is no `agent/bodies/*.md` left to read. When that assertion
  # is re-homed over `agent.agent_producer_playbooks`, it covers HANDOFF_COMMAND
  # alongside COMMAND — the contract is one contract with two halves, and a
  # playbook restating either of them is the same ISS-360 failure.
end
