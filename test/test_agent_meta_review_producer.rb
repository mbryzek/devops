#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-508: the weekly meta-review producer.
#
# Every assertion here pins a failure that is SILENT in production. This producer
# is the one that finds producers which have quietly stopped working, so each way
# it can quietly stop working is worth a test — a meta-reviewer that has itself
# gone dark reports nothing and looks exactly like a clean week.
class TestAgentMetaReviewProducer < Minitest::Test
  include DevTestSupport

  KEY = "meta-review".freeze

  def registry = @registry ||= Agent::Producers.load
  def producer = @producer ||= registry.fetch(:producers).find { |p| p.key == KEY }
  def playbook = @playbook ||= producer.body_text.to_s

  def test_the_producer_exists_and_files
    refute_nil producer, "the #{KEY} producer is gone from the registry"
    assert producer.files_issue?, "#{KEY}: a producer that files nothing reviews nothing"
  end

  # Without a body_file the filed issue falls back to claude-issues/default-body.md
  # and the claiming session does generic triage instead of the review — ISS-360,
  # where exactly that happened to the platform weekly review for a week.
  def test_it_ships_its_playbook
    assert_equal File.join(Agent::Paths.agent_dir, "bodies/meta-review.md"), producer.body_file
    refute_empty playbook, "#{KEY}: playbook is empty"
  end

  # No cheap check exists: deciding whether there is a gap means reading the run
  # history and the issues, which IS the review. A `check` runs inline in the tick
  # under the work lock with no timeout, so putting the job there would starve
  # every other producer and the claim path behind it.
  def test_it_has_no_check
    assert_nil producer.check, "#{KEY}: the review is the work — it must not run as a producer check"
    assert_equal "always", producer.file_when
  end

  # THE assertion. This producer closes out `fixed` against a document, and a
  # document-linked fix is advanced by hand — nothing reconciles it to `deployed`
  # or `verified`. `fixed` is non-terminal for dedup purposes, so an UNDATED
  # fingerprint would suppress every subsequent run, forever, from the first week
  # onward, with no error anywhere. That is detector D5's own failure mode; a
  # producer built to find dark producers must not be one.
  def test_the_fingerprint_is_dated
    assert_includes producer.fingerprint, Agent::Producers::DATE_TOKEN,
                    "#{KEY}: an undated fingerprint stops this producer permanently after its first run"
    assert_equal "meta-review:weekly:2026-08-09",
                 producer.fingerprint_at(Time.utc(2026, 8, 9, 11, 0)) # 07:00 America/New_York
  end

  def test_it_runs_weekly_after_the_sunday_reviews_and_pr_auto_merge
    assert_equal({ kind: :weekly, wday: 0, hour: 7, minute: 0 }, producer.schedule)
  end

  # A producer NEVER claims: it files for the queue and the claim path decides who
  # works it. A claimed issue nobody is working is invisible to `dev issues claim`
  # (which only offers OPEN ones), so a phantom claim does not mislabel the work,
  # it makes it unpickupable.
  # Scoped to `issues create` lines on purpose: `dev issues list --status open
  # --status claimed` is the dedup READ every filing must do first, and a blanket
  # substring match would forbid it.
  def test_the_playbook_never_tells_the_session_to_claim
    filings = playbook.lines.grep(/issues create/)
    refute_empty filings, "#{KEY}: a producer playbook that never files is not this producer"
    filings.each do |line|
      refute_includes line, "--status claimed",
                      "#{KEY}: this producer files; an issue it claims is one nobody can pick up"
    end
  end

  # Guardrail 2 of ISS-508, and the part most likely to be got wrong. A DECISION
  # filed `open` is one an autonomous session answers on Mike's behalf. ISS-504 is
  # the worked example: "the playbook says read-only and the run wrote" has two
  # defensible answers, and Mike picked one.
  def test_the_playbook_routes_decisions_to_needs_input_and_defects_to_open
    assert_includes playbook, "--status open"
    assert_includes playbook, "needs_input"
    assert_includes playbook, "ISS-504", "#{KEY}: the decision-vs-defect split needs its worked example"
  end

  # The `dev agent producers` "last run" column is built from the most recent 100
  # runs GLOBALLY, so any producer whose last run fell out of that window reads as
  # `never`. Four of the twelve weekly reviews read that way on 2026-08-05.
  # Detector D5 filing off that column would open four false issues on its first
  # run, which is the noise-generator outcome this producer must not have. The
  # per-key query filters server-side before it limits and is accurate.
  def test_the_playbook_requires_per_key_confirmation_before_calling_a_producer_dark
    assert_includes playbook, "dev agent runs <key>",
                    "#{KEY}: D5 must confirm per key — `dev agent producers` reports a false `never`"
    assert_includes playbook, "ISS-522", "#{KEY}: the trap needs its diagnosis linked"
  end

  # D4 detects playbooks that write to paths absent on the runner (ISS-503: four
  # bodies ending in a write to /Users/mbryzek/code/openclaw/...). A playbook that
  # commits the defect it detects is worse than one that detects nothing — and
  # this assertion is the same check D4 performs, run at test time against itself.
  def test_the_playbook_reports_somewhere_that_exists_on_the_runner
    assert_includes playbook, "~/code/claude/plans/data/meta-review-",
                    "#{KEY}: the durable copy must land under plans/, the one place a session may write"
    # The openclaw path may appear ONLY as the prohibition or as D4's worked
    # example, never as a destination. Scoped to the PARAGRAPH, not the line:
    # this prose is hard-wrapped, so the sentence that names the path and the one
    # that explains it are routinely different lines.
    paragraphs = playbook.split(/\n[ \t]*\n/).grep(%r{/Users/mbryzek/code/openclaw})
    refute_empty paragraphs, "#{KEY}: D4's worked example (ISS-503) is gone from the playbook"
    paragraphs.each do |para|
      assert_match(/Do not write|ISS-503/, para,
                   "#{KEY}: names the ISS-503 path as something other than the thing not to do:\n#{para}")
    end
  end

  # ISS-519 moves the registry and the playbooks into the platform and ISS-526
  # deletes devops/agent/ whole. This producer was added after that design was
  # written, so the migration inventory has to know it exists.
  def test_the_registry_entry_flags_itself_to_the_migration_epic
    yaml = File.read(Agent::Paths.producers_file)
    entry = yaml[/# ISS-508\..*?- key: #{KEY}\n(?:.*\n)*?      body_file: bodies\/meta-review\.md/m]
    refute_nil entry, "#{KEY}: registry entry lost its ISS-508 rationale block"
    assert_includes entry, "ISS-519", "#{KEY}: the migration epic must be able to find this producer"
  end
end
