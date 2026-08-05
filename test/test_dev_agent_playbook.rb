#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `Agent::Playbook` — the pointer a producer files instead of the playbook's text
# and the resolution a claiming runner does against its own checkout (ISS-505).
#
# The tests that matter here are the two ends of the round trip (what is written
# is what is read back) and the failure modes, because the failure modes are the
# whole reason the pointer is designed the way it is: a pointer that does not
# resolve must be LOUD, and a path that comes out of a human-editable issue body
# must never be trusted to stay inside the checkout.
class TestDevAgentPlaybook < Minitest::Test
  include DevTestSupport

  SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678".freeze

  PLAYBOOK = <<~MD
    # Daily slow-query review

    Review the platform's database query costs for the last 24 hours, find queries
    worth fixing, prove the fix, and open a PR.

    ## 1. Rank by total time, not mean

        dev queries top --limit 25
  MD

  # A stand-in devops checkout: a real `agent/bodies/` tree under a tmpdir, never
  # the developer's own checkout, so nothing here can be perturbed by an
  # uncommitted edit sitting in ~/code/devops.
  def with_checkout(files = { "agent/bodies/slow-query-review.md" => PLAYBOOK })
    Dir.mktmpdir do |root|
      files.each do |rel, content|
        FileUtils.mkdir_p(File.join(root, File.dirname(rel)))
        File.write(File.join(root, rel), content)
      end
      original = ENV["DEV_AGENT_DEVOPS_REPO"]
      ENV["DEV_AGENT_DEVOPS_REPO"] = root
      begin
        stub_singleton(Agent::Checkout, :head_sha, ->(*) { SHA }) { yield root }
      ensure
        ENV["DEV_AGENT_DEVOPS_REPO"] = original
      end
    end
  end

  # ---- the round trip ----

  # The producer writes the line and the claiming runner reads it back. These are
  # the two halves of one contract and they live in one module precisely so a
  # change to the format cannot update only one side.
  def test_a_written_pointer_reads_back_as_the_same_path
    line = Agent::Playbook.pointer_line("agent/bodies/slow-query-review.md")
    pointer = Agent::Playbook.pointer_in("some evidence\n\n#{line}\n\nmore prose")
    assert_equal "agent/bodies/slow-query-review.md", pointer.path
    assert_nil pointer.target
  end

  def test_a_child_pointer_carries_its_target_through_the_round_trip
    line = Agent::Playbook.pointer_line("agent/bodies/dependency-upgrade-app.md", target: "platform")
    pointer = Agent::Playbook.pointer_in(line)
    assert_equal "agent/bodies/dependency-upgrade-app.md", pointer.path
    assert_equal "platform", pointer.target
  end

  # `{child}` used to be substituted when the issue was FILED. With the text
  # resolved at claim time instead, the substitution has to travel on the pointer
  # or every child of an epic would read the literal token.
  def test_the_target_substitutes_the_child_token_at_resolve_time
    body = "# Dependency upgrades: {child}\n\nUpgrade **{child}** and report.\n"
    with_checkout({ "agent/bodies/dependency-upgrade-app.md" => body }) do
      resolved = Agent::Playbook.resolve_in(
        Agent::Playbook.pointer_line("agent/bodies/dependency-upgrade-app.md", target: "platform"),
      )
      assert_match(/Upgrade \*\*platform\*\* and report/, resolved.text)
      refute_match(/\{child\}/, resolved.text, "the token must not survive into the session's prompt")
    end
  end

  # ---- what must NOT be mistaken for a pointer ----

  # ISS-505's own body contains an indented, unbackticked example of the recorded
  # comment line. Prose that merely talks about a playbook is not a pointer, and
  # a marker loose enough to match it would hard-fail issues that never had one.
  def test_prose_that_merely_mentions_a_playbook_is_not_a_pointer
    [
      "       Playbook: agent/bodies/slow-query-review.md @ a1b2c3d",
      "See Playbook: `agent/bodies/slow-query-review.md` for the procedure",
      "Playbook: agent/bodies/slow-query-review.md",
      "Playbook: `bodies/slow-query-review.md`",
    ].each do |line|
      assert_nil Agent::Playbook.pointer_in(line), "must not match: #{line}"
    end
  end

  def test_an_issue_with_no_pointer_resolves_to_nothing_at_all
    with_checkout do
      assert_nil Agent::Playbook.resolve_in("A human wrote this issue by hand.")
      assert_nil Agent::Playbook.resolve_in(nil)
    end
  end

  # ---- the hard failures ----

  # ISS-360: a producer ported without its playbook fell back to generic triage
  # and filed issues instead of shipping PRs for a week, with nothing saying so.
  # A pointer that does not resolve must never be quiet.
  def test_a_pointer_at_a_file_that_is_not_there_raises
    with_checkout do
      error = assert_raises(Agent::Playbook::MissingError) do
        Agent::Playbook.resolve_in(Agent::Playbook.pointer_line("agent/bodies/gone.md"))
      end
      assert_match(/did not resolve/, error.message)
    end
  end

  # The path is read back out of an issue body, which a human can edit. It is
  # input, not configuration.
  def test_a_pointer_that_traverses_out_of_the_checkout_raises
    with_checkout do
      ["agent/bodies/../../../../etc/passwd.md", "agent/../../secrets.md"].each do |path|
        assert_raises(Agent::Playbook::MissingError) { Agent::Playbook.read(path) }
      end
    end
  end

  def test_a_pointer_at_something_outside_agent_raises
    with_checkout do
      ["lib/agent/tick.rb", "agent/producers.yml", "/etc/passwd"].each do |path|
        assert_raises(Agent::Playbook::MissingError) { Agent::Playbook.read(path) }
      end
    end
  end

  # ---- the audit trail ----

  def test_a_resolved_playbook_records_the_sha_it_was_read_at
    with_checkout do
      resolved = Agent::Playbook.resolve_in(Agent::Playbook.pointer_line("agent/bodies/slow-query-review.md"))
      assert_equal SHA, resolved.sha
      assert_equal "agent/bodies/slow-query-review.md @ #{SHA[0, 8]}", resolved.label
      assert_equal "https://github.com/mbryzek/devops/blob/#{SHA}/agent/bodies/slow-query-review.md",
                   resolved.permalink
    end
  end

  # A machine that is not a git checkout reports a nil sha elsewhere already; the
  # link must still go somewhere real rather than to `/blob//`.
  def test_a_missing_sha_permalinks_to_main_rather_than_to_nothing
    assert_equal "https://github.com/mbryzek/devops/blob/main/agent/bodies/x.md",
                 Agent::Playbook.permalink("agent/bodies/x.md", nil)
  end

  # ---- the abstract that stays inline ----

  def test_the_abstract_is_the_heading_and_the_opening_paragraph
    abstract = Agent::Playbook.abstract(PLAYBOOK)
    assert_match(/\A\*\*Daily slow-query review\*\*/, abstract)
    assert_match(/find queries\nworth fixing/, abstract)
    refute_match(/Rank by total time/, abstract, "only the opening paragraph stays inline")
  end

  def test_a_playbook_with_no_heading_or_no_paragraph_does_not_abstract_cleanly
    assert Agent::Playbook.abstracts_cleanly?(PLAYBOOK)
    refute Agent::Playbook.abstracts_cleanly?("Just a paragraph, no heading.\n")
    refute Agent::Playbook.abstracts_cleanly?("# Heading and nothing else\n")
    refute Agent::Playbook.abstracts_cleanly?("")
  end

  # The block a producer files: enough to read in admin, plus the pointer and a
  # link to the current text — and never the procedure itself.
  def test_the_pointer_block_carries_the_abstract_the_pointer_and_a_permalink
    with_checkout do
      block = Agent::Playbook.pointer_block("agent/bodies/slow-query-review.md")
      assert_match(/\*\*Daily slow-query review\*\*/, block)
      assert_match(/^Playbook: `agent\/bodies\/slow-query-review\.md`$/, block)
      assert_match(%r{blob/main/agent/bodies/slow-query-review\.md}, block)
      refute_match(/Rank by total time/, block, "the procedure must not be copied into the issue")
    end
  end

  # `agent/bodies/x.md`, not `bodies/x.md` and not an absolute path: the pointer
  # is repo-relative because that is what a GitHub permalink needs.
  def test_repo_relative_paths_are_rooted_at_the_repo_not_at_agent
    with_checkout do |root|
      assert_equal "agent/bodies/slow-query-review.md",
                   Agent::Playbook.repo_relative(File.join(root, "agent/bodies/slow-query-review.md"))
      assert_nil Agent::Playbook.repo_relative(nil)
    end
  end
end
