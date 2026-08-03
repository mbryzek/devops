#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The dispatcher's pure decision functions: outcome classification, slug/branch
# generation, the producer registry's validation and in-flight predicate, and the
# retention rules. Each of these decides something irreversible-ish (a status
# transition, an rm -rf), and each is a plain function so it can be pinned here.
class TestDevAgentOutcome < Minitest::Test
  include DevTestSupport

  READY_PR = { "url" => "https://github.com/mbryzek/platform/pull/9", "isDraft" => false }.freeze
  DRAFT_PR = { "url" => "https://github.com/mbryzek/platform/pull/9", "isDraft" => true }.freeze

  def classify(**overrides)
    Agent::Outcome.classify(**{ pr: nil, plans_committed: false, exit_code: 0,
                                producer_filed: false, attempt: 1, timed_out: false }.merge(overrides))
  end

  # ---- outcome classification ----

  def test_ready_pr_is_fixed_and_carries_the_url
    result = classify(pr: READY_PR)
    assert_equal "ready_pr", result.name
    assert_equal "fixed", result.status
    assert_equal READY_PR["url"], result.url
    assert_equal "succeeded", result.lease_outcome
  end

  # A ready PR wins even over a non-zero exit: the artifact is the outcome, and
  # `claude --print` exiting non-zero after pushing a reviewable PR must not throw
  # the work away.
  def test_ready_pr_wins_over_a_nonzero_exit
    assert_equal "fixed", classify(pr: READY_PR, exit_code: 1).status
  end

  def test_draft_pr_is_not_a_result
    result = classify(pr: DRAFT_PR)
    assert_equal "failed", result.name
    assert_equal "open", result.status
    assert_match(/never marked ready/, result.reason)
  end

  def test_design_document_is_needs_review
    result = classify(plans_committed: true)
    assert_equal "design_document", result.name
    assert_equal "needs_review", result.status
  end

  # The asymmetry that keeps the fleet honest: agents never self-dismiss
  # human-filed work.
  def test_nothing_to_do_dismisses_only_producer_filed_issues
    assert_equal "dismissed", classify(producer_filed: true).status
    assert_equal "needs_input", classify(producer_filed: false).status
    assert_equal "nothing_to_do", classify(producer_filed: false).name
  end

  def test_crash_is_retryable_until_the_attempt_limit
    assert_equal "open", classify(exit_code: 2).status
    assert_equal "failed", classify(exit_code: 2).name
    assert_equal "open", classify(exit_code: 2, attempt: 2).status

    gave_up = classify(exit_code: 2, attempt: Agent::Outcome::MAX_ATTEMPTS)
    assert_equal "gave_up", gave_up.name
    assert_equal "needs_input", gave_up.status
    assert_equal "failed", gave_up.lease_outcome
  end

  # A killed session never writes an exit code. Treated as a failure, never as a
  # clean "nothing to do" — otherwise a timed-out producer issue would be
  # silently dismissed.
  def test_missing_exit_code_is_a_failure_not_a_clean_exit
    result = classify(exit_code: nil, timed_out: true, producer_filed: true)
    assert_equal "failed", result.name
    assert_equal "open", result.status
  end

  def test_success_predicate_drives_workspace_cleanup
    assert Agent::Outcome.success?(classify(pr: READY_PR))
    assert Agent::Outcome.success?(classify(plans_committed: true))
    assert Agent::Outcome.success?(classify(producer_filed: true))
    refute Agent::Outcome.success?(classify(exit_code: 2))
  end

  # ---- slug / branch ----

  def test_slug_shape_and_length_bound
    assert_equal "i120_x4q", Agent::Workspace.slug(120, suffix: "x4q")
    # The ceiling exists because macOS caps a unix socket path at 104 bytes and
    # sbt builds <feature>/<repo>/project/.sbtboot/server/<hash>/sock under it.
    (1..99_999).step(7919) do |n|
      slug = Agent::Workspace.slug(n)
      assert_operator slug.length, :<=, Agent::Workspace::MAX_SLUG_LENGTH, "slug #{slug} too long"
      assert_match(/\Ai\d+_[a-z0-9]{3}\z/, slug)
    end
  end

  def test_slug_refuses_to_generate_an_oversized_name
    assert_raises(RuntimeError) { Agent::Workspace.slug("1234567890123456789") }
  end

  def test_two_attempts_on_one_issue_get_different_slugs
    slugs = 20.times.map { Agent::Workspace.slug(120) }
    assert_operator slugs.uniq.length, :>, 1, "a fixed suffix would collide two attempts"
  end

  # The GC pattern must match exactly what the executor creates, and nothing
  # else: ~/code/ai also holds Mike's own feature dirs and gc runs rm -rf.
  def test_gc_slug_pattern_matches_agent_dirs_only
    assert_match Agent::Gc::AGENT_SLUG, Agent::Workspace.slug(120, suffix: "x4q")
    ["cr-backfill-coord", "agent-dispatch", "i120", "i120_toolong", "xi120_abc"].each do |name|
      refute_match Agent::Gc::AGENT_SLUG, name, "#{name} must not look like an agent workspace"
    end
  end

  # ---- producer registry ----

  def registry_yaml
    <<~YAML
      timezone: America/New_York
      producers:
        - key: invariants-platform
          schedule: every 1 hour
          check: dev invariants check --app platform
          file_when: check_fails
          issue:
            category: infrastructure
            severity: high
            title: Run dev invariants
            fingerprint: invariants:platform

    YAML
  end

  def test_parses_the_shipped_registry
    registry = Agent::Producers.load
    assert_equal "America/New_York", registry.fetch(:timezone)
    keys = registry.fetch(:producers).map(&:key)
    assert_includes keys, "invariants-platform"
    assert_includes keys, "issue-reconcile"
    assert_includes keys, "agent-gc", "retention must run as a producer, not a cron"
    registry.fetch(:producers).each do |producer|
      assert_kind_of Hash, producer.schedule, "#{producer.key}: schedule failed to parse"
      next unless producer.files_issue?
      assert_includes ISSUE_CATEGORIES, producer.issue.fetch("category"),
                      "#{producer.key}: files into a category the spec does not have"
    end
  end

  def test_registry_rejects_a_timezone_abbreviation
    error = assert_raises(Agent::Producers::ConfigError) do
      Agent::Producers.parse(registry_yaml.sub("America/New_York", "EDT"))
    end
    assert_match(/IANA/, error.message)
  end

  def test_registry_rejects_a_filing_producer_with_no_issue_block
    yaml = "timezone: America/New_York\nproducers:\n  - key: x\n    schedule: every 1 hour\n    check: true\n    file_when: check_fails\n"
    assert_raises(Agent::Producers::ConfigError) { Agent::Producers.parse(yaml) }
  end

  def test_registry_rejects_never_carrying_an_issue_block
    yaml = registry_yaml.sub("file_when: check_fails", "file_when: never")
    assert_raises(Agent::Producers::ConfigError) { Agent::Producers.parse(yaml) }
  end

  def test_registry_rejects_duplicate_keys
    yaml = "#{registry_yaml}  - key: invariants-platform\n    schedule: every 2 hours\n    check: \"true\"\n    file_when: never\n"
    error = assert_raises(Agent::Producers::ConfigError) { Agent::Producers.parse(yaml) }
    assert_match(/duplicate/, error.message)
  end

  # ---- the in-flight predicate ----
  #
  # `fixed` counting as in-flight is what makes "don't re-file while a PR is
  # open" fall out with no GitHub call at all.
  def test_in_flight_covers_every_non_terminal_status
    %w[open claimed needs_review needs_input fixed deployed].each do |status|
      issues = [{ "fingerprint" => "invariants:platform", "status" => status }]
      assert Agent::Producers.in_flight?(issues, "invariants:platform"), "#{status} must block a re-file"
    end
  end

  def test_terminal_statuses_release_the_fingerprint
    %w[verified dismissed].each do |status|
      issues = [{ "fingerprint" => "invariants:platform", "status" => status }]
      refute Agent::Producers.in_flight?(issues, "invariants:platform"), "#{status} must allow a re-file"
    end
  end

  def test_in_flight_is_scoped_to_the_fingerprint
    issues = [{ "fingerprint" => "codegen:sync", "status" => "open" }]
    refute Agent::Producers.in_flight?(issues, "invariants:platform")
    refute Agent::Producers.in_flight?(issues, nil)
    refute Agent::Producers.in_flight?([{ "status" => "open" }], "invariants:platform")
  end

  def test_due_selects_only_producers_past_their_schedule
    registry = Agent::Producers.parse(registry_yaml)
    now = Time.utc(2026, 8, 3, 12, 0, 0)
    assert_empty Agent::Producers.due(registry, last_run_by_key: { "invariants-platform" => now - 60 }, now: now)
    assert_equal ["invariants-platform"],
                 Agent::Producers.due(registry, last_run_by_key: {}, now: now).map(&:key)
  end

  # ---- retention ----

  def test_retention_windows_favour_failures
    assert_equal Agent::Gc::TERMINAL_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "ready_pr" })
    assert_equal Agent::Gc::TERMINAL_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "nothing_to_do" })
    assert_equal Agent::Gc::FAILED_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "failed" })
    assert_equal Agent::Gc::FAILED_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "gave_up" })
    assert_operator Agent::Gc::FAILED_ISSUE_DAYS, :>, Agent::Gc::TERMINAL_ISSUE_DAYS
  end

  def test_gc_plan_applies_one_rule_per_kind
    Dir.mktmpdir do |root|
      logs = File.join(root, "logs")
      workspaces = File.join(root, "ai")
      with_env("DEV_AGENT_LOG_ROOT" => logs, "DEV_AGENT_WORKSPACE_ROOT" => workspaces) do
        now = Time.utc(2026, 8, 3, 12, 0, 0)
        write(File.join(logs, "tick", "2026-06-01.log"), "old")     # 63 days
        write(File.join(logs, "tick", "2026-08-01.log"), "recent")  # 2 days
        write_meta(logs, 100, "ready_pr", now - 20 * 86_400)        # terminal, keep 14 -> collect
        write_meta(logs, 101, "ready_pr", now - 5 * 86_400)         # terminal, keep 14 -> keep
        write_meta(logs, 102, "gave_up",  now - 20 * 86_400)        # failed,   keep 30 -> keep
        write_meta(logs, 103, nil, nil)                             # still running -> never collect
        stale = File.join(workspaces, "i120_abc")
        FileUtils.mkdir_p(stale)
        File.utime(now - 9 * 86_400, now - 9 * 86_400, stale)
        fresh = File.join(workspaces, "i121_abc")
        FileUtils.mkdir_p(fresh)
        mine = File.join(workspaces, "agent-dispatch")
        FileUtils.mkdir_p(mine)
        File.utime(now - 900 * 86_400, now - 900 * 86_400, mine)

        paths = Agent::Gc.plan(now: now).map(&:first)
        assert_includes paths, File.join(logs, "tick", "2026-06-01.log")
        refute_includes paths, File.join(logs, "tick", "2026-08-01.log")
        assert_includes paths, File.join(logs, "issues", "ISS-100")
        refute_includes paths, File.join(logs, "issues", "ISS-101")
        refute_includes paths, File.join(logs, "issues", "ISS-102")
        refute_includes paths, File.join(logs, "issues", "ISS-103")
        assert_includes paths, stale
        refute_includes paths, fresh
        refute_includes paths, mine, "gc must never touch a hand-made feature dir"
      end
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def write_meta(logs, number, outcome, finished_at)
    meta = { "issue" => number }
    meta["outcome"] = { "name" => outcome } if outcome
    meta["finished_at"] = finished_at.utc.iso8601 if finished_at
    write(File.join(logs, "issues", "ISS-#{number}", "meta.json"), JSON.generate(meta))
  end

  def with_env(pairs)
    original = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end
end
