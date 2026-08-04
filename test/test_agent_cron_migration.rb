#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The openclaw crons that moved onto the agent (epic ISS-394, children ISS-395,
# ISS-397 through ISS-402).
#
# These assertions exist because every failure mode in this migration is SILENT.
# A missing producer is a job that stopped running with nobody notified; a missing
# `body_file` is ISS-360, where the platform weekly review was ported without its
# playbook and did generic triage for a week; a `check` on the six-hour dependency
# pipeline would hold the tick's work lock for a quarter of a day. None of those
# announce themselves.
class TestAgentCronMigration < Minitest::Test
  include DevTestSupport

  def registry = @registry ||= Agent::Producers.load
  def producers = registry.fetch(:producers)
  def producer(key) = producers.find { |p| p.key == key }

  # Every openclaw cron this epic retired, and the producer that replaced it.
  MIGRATED = {
    "aidirs-prune"                => "aidirs-prune",
    "docker-prune"                => "docker-prune",
    "browserslist-update"         => "browserslist-update",
    "depsguard-weekly"            => "depsguard",
    "dep-upgrade-nightly"         => "dependency-upgrade",
    "daily-perf-prs"              => "daily-perf-prs",
    "daily-error-triage"          => "daily-error-triage",
    "slow-query-review"           => "slow-query-review",
    "platform-memory-improvement" => "platform-memory-improvement",
    "api-lint-weekly-pr"          => "api-lint",
  }.freeze

  def test_every_retired_cron_has_a_producer
    MIGRATED.each do |cron, key|
      assert producer(key), "cron `#{cron}` was retired with no `#{key}` producer to replace it"
    end
  end

  # A producer that files an issue with no playbook falls back to
  # claude-issues/default-body.md and does generic triage — a different job than
  # the one the producer was written to schedule (ISS-360).
  #
  # `invariants-*` and `codegen-sync` are deliberately exempt: their check's
  # stdout IS the brief, so the failure list arrives as the evidence block.
  def test_every_migrated_producer_that_files_ships_a_playbook
    MIGRATED.each_value do |key|
      p = producer(key)
      next unless p.files_issue?
      assert p.body_file, "#{key}: files an issue with no issue.body_file"
      refute_empty p.body_text.to_s, "#{key}: playbook is empty"
    end
  end

  # `check` runs INLINE in the tick, under the work lock, with no timeout. The
  # nightly dependency pipeline runs for hours; putting it in a check would starve
  # every other producer and the claim path behind it. That is the entire reason
  # ISS-397 was not ported the way its thin siblings were.
  def test_the_long_running_jobs_file_rather_than_check
    %w[dependency-upgrade daily-perf-prs slow-query-review platform-memory-improvement daily-error-triage].each do |key|
      p = producer(key)
      assert_nil p.check, "#{key}: a multi-hour job must not run as a producer check"
      assert_equal "always", p.file_when, "#{key}: must file unconditionally — it has no cheap check"
    end
  end

  # The chores that act directly must NOT carry an issue block: they are the work,
  # and filing an issue for a completed chore is queue noise.
  def test_the_direct_chores_file_nothing
    %w[aidirs-prune docker-prune browserslist-update].each do |key|
      assert_equal "never", producer(key).file_when, "#{key}: acts directly, so it must file nothing"
      refute_nil producer(key).check, "#{key}: file_when never needs a check to run"
    end
  end

  # depsguard is the split the producer contract is built for: a cheap scan whose
  # verdict is its exit code, and an expensive fix that happens as claimed work.
  def test_depsguard_detects_and_files_but_does_not_fix
    p = producer("depsguard")
    assert_equal "dev depsguard", p.check
    assert_equal "check_fails", p.file_when
    assert_equal "depsguard:scan", p.fingerprint
  end

  # Every fingerprint the registry can file, epics and children included. A
  # collision here is invisible in production: the second issue is never filed,
  # it just silently increments the first one's occurrence count.
  def test_fingerprints_are_unique_across_the_whole_registry
    fingerprints = producers.select(&:files_issue?).flat_map do |p|
      [p.fingerprint] + p.children.map(&:fingerprint)
    end
    dupes = fingerprints.tally.select { |_, n| n > 1 }.keys
    assert_empty dupes, "two producers would dedup each other: #{dupes.join(', ')}"
  end

  # ---- ISS-397: the nightly upgrade is an epic with one child per repo -------

  def test_the_dependency_upgrade_producer_files_an_epic_per_repo
    p = producer("dependency-upgrade")
    assert p.epic?, "the nightly upgrade files an epic, not one issue for six repos"
    assert_equal Dependencies::Updates::APPS.keys.sort, p.children.map(&:name).sort,
                 "children must be exactly the repos `dev dependencies upgrade` watches — " \
                 "a repo in one list and not the other is a repo that never gets upgraded"
  end

  # The epic reaches `deployed` when its children are terminal and then waits for
  # Mike to verify. `deployed` is non-terminal for producer dedup, so an undated
  # epic fingerprint would stop the NIGHTLY producer filing until he clicked
  # verify. The children carry the real dedup instead.
  def test_the_epic_fingerprint_is_dated_and_the_children_are_not
    p = producer("dependency-upgrade")
    assert_includes p.fingerprint, Agent::Producers::DATE_TOKEN
    assert_equal "dependencies:upgrade:2026-08-05", p.fingerprint_at(Time.utc(2026, 8, 5, 7, 45))
    p.children.each do |child|
      refute_includes child.fingerprint, Agent::Producers::DATE_TOKEN,
                      "#{child.name}: an unfinished repo must suppress tonight's re-file"
      assert_equal "dependencies:upgrade:#{child.name}", child.fingerprint
    end
  end

  # Each child runs ONE repo. A playbook that told the session to run the whole
  # pipeline would have all six children upgrading all six repos.
  def test_each_child_playbook_names_its_own_repo_and_only_its_own
    producer("dependency-upgrade").children.each do |child|
      assert_includes child.body_text, "--app #{child.name}",
                      "#{child.name}: the playbook must scope the run to this repo"
      refute_includes child.body_text, Agent::Producers::CHILD_TOKEN,
                      "#{child.name}: an unsubstituted {child} reached the filed body"
    end
  end

  # The briefing reads the newest dep-up workdir's status file. Six children
  # writing six workdirs would leave it reporting one repo and dropping five.
  def test_the_dependency_children_share_one_days_status_file
    child = producer("dependency-upgrade").children.first
    assert_includes child.body_text, "dependencies-status.json",
                    "the playbook must name the file the briefing reads"

    Dir.mktmpdir do |dir|
      write_dependencies_status_json(dir, { "platform" => { status: :ok, pr_url: "https://pr/1" } })
      write_dependencies_status_json(dir, { "acumen" => { status: :in_sync } })
      rows = JSON.parse(File.read(File.join(dir, "dependencies-status.json")))
      assert_equal %w[acumen platform], rows.map { |r| r["repo"] },
                   "a second repo's run overwrote the first — the briefing would report one repo of six"
      assert_equal "https://pr/1", rows.find { |r| r["repo"] == "platform" }["pr_url"]
    end
  end

  # ---- ISS-402: api-lint files work, it does not do it -----------------------

  # It used to be a shell script that cloned, linted, pushed and opened PRs from
  # inside the producer check. A producer creates work; it does not do it — and a
  # push that failed in there looked exactly like a week with no drift.
  def test_api_lint_files_an_issue_instead_of_opening_prs_itself
    p = producer("api-lint")
    assert_equal "always", p.file_when
    assert_nil p.check, "a producer check must not clone repos and open PRs"
    assert_equal "api-lint:weekly", p.fingerprint
    assert_includes p.body_text, "api lint"
    refute File.exist?(File.expand_path("../scripts/api-lint-pr.sh", __dir__)),
           "the script did the work the claiming session now does"
  end

  # The repos the retired cron covered, plus the two that also own specs.
  def test_the_api_lint_playbook_covers_every_spec_owning_repo
    text = producer("api-lint").body_text
    %w[platform acumen dependency lib-ai].each do |repo|
      assert_includes text, repo, "api-lint playbook does not mention #{repo}"
    end
  end

  # Schedules are the retired crons' schedules, preserved. A migration that
  # quietly moved a job to a different hour would be indistinguishable from one
  # that worked, until something else started colliding with it.
  CRON_SCHEDULES = {
    "aidirs-prune"                => "daily at 6:00am",
    "docker-prune"                => "daily at 5:08am",
    "browserslist-update"         => "weekly on monday at 4:13am",
    "depsguard"                   => "weekly on monday at 5:13am",
    "dependency-upgrade"          => "daily at 3:45am",
    "daily-perf-prs"              => "daily at 3:03am",
    "slow-query-review"           => "daily at 3:30am",
    "daily-error-triage"          => "daily at 5:45am",
    "api-lint"                    => "weekly on wednesday at 3:30am",
  }.freeze

  def test_schedules_match_the_crons_they_replace
    CRON_SCHEDULES.each do |key, text|
      assert_equal text, producer(key).schedule_text, "#{key}: schedule drifted from the cron it replaced"
    end
  end

  # Every playbook whose job feeds a morning-briefing section must name the file
  # that section reads. The briefing skips a section whose status file is stale,
  # so a playbook that forgets to write it makes the section vanish silently.
  BRIEFING_FILES = {
    "daily-perf-prs"              => "daily-perf-prs-status.md",
    "slow-query-review"           => "slow-query-review-status.md",
    "platform-memory-improvement" => "platform-memory-improvement.md",
  }.freeze

  def test_playbooks_name_the_briefing_status_file_they_must_write
    BRIEFING_FILES.each do |key, file|
      assert_includes producer(key).body_text, file,
                      "#{key}: playbook never mentions #{file}, so the briefing section would go dark"
    end
  end

  # The chores whose status file moved into the command (lib/briefing.rb) instead
  # of into a playbook — the other half of the same guarantee.
  def test_the_commands_write_the_briefing_files_their_crons_used_to
    src = File.read(File.expand_path("../bin/dev", __dir__))
    %w[aidirs-prune-status.md docker-prune-status.md browserslist-status.md].each do |file|
      assert_includes src, file, "nothing writes #{file} any more — its briefing section would go dark"
    end
  end

  # Ported playbooks must not carry the openclaw scaffolding a lease replaces, or
  # the review gates Reviewable replaced.
  STALE_PATTERNS = {
    "nohup"                      => "a lease and a heartbeat replace fire-and-forget backgrounding",
    "disown"                     => "a lease and a heartbeat replace fire-and-forget backgrounding",
    "openclaw system event"      => "an agent session reports through its run record, not openclaw",
    "code-review:code-review"    => "Reviewable replaced the automated review rounds",
    "reviewable.io"              => "never report a Reviewable URL",
  }.freeze

  def test_ported_playbooks_dropped_the_stale_guidance
    Dir[File.expand_path("../agent/bodies/*.md", __dir__)].each do |path|
      text = File.read(path)
      STALE_PATTERNS.each do |pattern, why|
        refute_includes text.downcase, pattern.downcase, "#{File.basename(path)}: #{why}"
      end
    end
  end

  # A NewRelic API key was pasted into the openclaw-era runbook. Playbooks live in
  # a git repo; a secret that gets ported forward gets committed.
  def test_no_playbook_carries_a_credential
    Dir[File.expand_path("../agent/bodies/*.md", __dir__)].each do |path|
      refute_match(/NRAK-[A-Z0-9]{20,}/, File.read(path), "#{File.basename(path)}: contains a NewRelic API key")
    end
  end

  # CLAUDE.md: never `--base` (it is how stacked PRs happen), never a shallow
  # clone. The retired openclaw script did both, and the playbook that replaced
  # it is where that guidance now has to live.
  def test_playbooks_that_open_prs_carry_the_pr_conventions
    text = producer("api-lint").body_text
    refute_match(/gh pr create[^\n]*--base/, text, "never pass --base to gh pr create")
    refute_match(/git clone[^\n]*--depth/, text, "no shallow clones")
    assert_includes text, "--draft", "PRs open as drafts, then go ready"
  end

  # One scheduler per job. The dependency pipeline had three at once — an openclaw
  # cron, a launchd plist, and (now) a producer.
  def test_the_dependency_launchd_plist_is_gone
    refute File.exist?(File.expand_path("../launchd/com.bryzek.dev-dependencies.plist", __dir__)),
           "the launchd plist is a second scheduler for the job the dependency-upgrade producer owns"
  end
end
