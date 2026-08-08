#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the readiness logic behind `dev features reconcile`: the pure decision of
# whether a (app, baseline_version) pair has cleared, and whether a removal as a
# whole is ready. No network — the HTTP paths exit before any request without
# credentials.
#
# The property under test throughout is fail-closed. Soft deleting a flag's row
# while the old code is still serving flips the behavior back for real users, so
# anything this cannot positively confirm must stay pending.
class TestDevFeatures < Minitest::Test
  include DevTestSupport

  RECORDED_AT = "2026-07-01T12:00:00Z".freeze

  # `features reconcile` loads the apps registry itself, and left real that is
  # `pkl eval` over ~/code/env/apps (RegistryGuard, ISS-795). An EMPTY fleet is
  # the honest stand-in here rather than an under-specified one: the removals
  # these tests feed it name no apps, so the registry is carried through to a
  # version probe that is never reached.
  def setup
    registry_fleet(Struct.new(:deploy_tracked).new([]))
  end

  def pair(app: "platform", baseline: "1.0.0")
    { "app" => app, "baseline_version" => baseline }
  end

  def removal(apps:, created_at: RECORDED_AT, feature: "revenue_business_line")
    { "subproject" => "playbook", "feature" => feature, "created_at" => created_at, "apps" => apps }
  end

  # ---------- feature_pair_confirmed? ----------

  def test_confirmed_when_released_after_the_removal_was_recorded
    info = { "version" => "1.1.0", "released_at" => "2026-07-05T12:00:00Z" }
    assert feature_pair_confirmed?(info, pair, RECORDED_AT)
  end

  def test_not_confirmed_when_the_release_predates_the_removal
    # A tag newer than the baseline but cut BEFORE the removal merged cannot
    # contain it. The timestamp is what makes this distinguishable.
    info = { "version" => "1.1.0", "released_at" => "2026-06-20T12:00:00Z" }
    refute feature_pair_confirmed?(info, pair, RECORDED_AT)
  end

  def test_falls_back_to_tag_comparison_without_a_timestamp
    assert feature_pair_confirmed?({ "version" => "1.1.0" }, pair, RECORDED_AT)
    refute feature_pair_confirmed?({ "version" => "1.0.0" }, pair, RECORDED_AT)
  end

  def test_falls_back_to_tag_comparison_on_an_unparseable_timestamp
    info = { "version" => "1.1.0", "released_at" => "not-a-date" }
    assert feature_pair_confirmed?(info, pair, RECORDED_AT)
  end

  # The fail-closed cases: every one of these is a state where the CLI does not
  # know, and not knowing must never advance a cleanup.

  def test_not_confirmed_when_the_probe_errored
    refute feature_pair_confirmed?({ error: "unknown app 'nope'" }, pair, RECORDED_AT)
  end

  def test_not_confirmed_when_there_is_no_version_info_at_all
    refute feature_pair_confirmed?(nil, pair, RECORDED_AT)
  end

  def test_not_confirmed_when_the_live_version_is_missing
    refute feature_pair_confirmed?({ "released_at" => "2026-07-05T12:00:00Z" }, pair, RECORDED_AT)
  end

  def test_not_confirmed_when_the_baseline_is_missing_and_no_timestamp
    refute feature_pair_confirmed?({ "version" => "1.1.0" }, { "app" => "platform" }, RECORDED_AT)
  end

  # ---------- feature_removal_state ----------

  def state_for(rem, versions)
    registry = Object.new
    cache = {}
    # Stub the per-app lookup rather than the registry: fetch_release_info is the
    # shared probe and is covered by the deploy and release-tag tests.
    orig = method(:named_release_info)
    define_singleton_method(:named_release_info) { |_r, _c, app| versions[app] }
    begin
      feature_removal_state(registry, cache, rem)
    ensure
      define_singleton_method(:named_release_info, orig)
    end
  end

  def test_ready_only_when_every_app_has_cleared
    rem = removal(apps: [pair(app: "platform"), pair(app: "playbook-app", baseline: "0.1.75")])
    versions = {
      "platform" => { "version" => "1.1.0", "released_at" => "2026-07-05T12:00:00Z" },
      "playbook-app" => { "version" => "0.1.76", "released_at" => "2026-07-06T12:00:00Z" },
    }
    assert state_for(rem, versions)[:ready]
  end

  def test_not_ready_when_one_app_still_lags
    rem = removal(apps: [pair(app: "platform"), pair(app: "playbook-app", baseline: "0.1.75")])
    versions = {
      "platform" => { "version" => "1.1.0", "released_at" => "2026-07-05T12:00:00Z" },
      "playbook-app" => { "version" => "0.1.75", "released_at" => "2026-06-01T12:00:00Z" },
    }
    state = state_for(rem, versions)
    refute state[:ready]
    assert_equal 1, state[:pairs].count { |p| !p[:confirmed] }
  end

  # The vacuous-truth guard. `all?` on an empty list is true, so a removal with no
  # apps would be "ready" on its first check and delete the flag row immediately.
  # The API rejects creating one; this makes even a hand-inserted row inert.
  def test_a_removal_with_no_apps_is_never_ready
    refute state_for(removal(apps: []), {})[:ready]
  end

  def test_pair_detail_surfaces_the_probe_error
    rem = removal(apps: [pair(app: "platform")])
    state = state_for(rem, { "platform" => { error: "no prod probe" } })
    refute state[:ready]
    assert_includes state[:pairs].first[:detail], "no prod probe"
  end

  def test_pair_detail_shows_baseline_and_live_versions
    rem = removal(apps: [pair(app: "platform", baseline: "1.0.0")])
    state = state_for(rem, { "platform" => { "version" => "1.2.0", "released_at" => "2026-07-05T12:00:00Z" } })
    assert_includes state[:pairs].first[:detail], "1.0.0 -> 1.2.0"
  end

  # ---------- retire flag parsing ----------
  #
  # Regression: the first cut of this command used parse_common_flags, which
  # treats --app as a SINGLE filter. Both apps were swallowed before the command
  # saw them, so every invocation failed with "at least one --app is required" —
  # the command could never succeed. Repeats have to survive parsing.

  def test_retire_collects_repeated_app_flags
    flags = features_retire_parse_flags(%w[playbook revenue_business_line --app platform --app playbook-app])
    assert_equal %w[platform playbook-app], flags[:apps]
    assert_equal %w[playbook revenue_business_line], flags[:positional]
    refute flags[:use_localhost]
  end

  def test_retire_collects_a_single_app_flag
    flags = features_retire_parse_flags(%w[playbook some_flag --app platform])
    assert_equal %w[platform], flags[:apps]
  end

  def test_retire_separates_localhost_from_positionals
    flags = features_retire_parse_flags(%w[playbook some_flag --app platform --localhost])
    assert flags[:use_localhost]
    assert_equal %w[playbook some_flag], flags[:positional]
    assert_equal %w[platform], flags[:apps]
  end

  def test_retire_handles_flags_before_positionals
    flags = features_retire_parse_flags(%w[--app platform playbook some_flag])
    assert_equal %w[platform], flags[:apps]
    assert_equal %w[playbook some_flag], flags[:positional]
  end

  def test_retire_reports_no_apps_when_none_given
    flags = features_retire_parse_flags(%w[playbook some_flag])
    assert_empty flags[:apps]
  end

  # ---------- paths ----------

  def test_feature_removal_path_encodes_both_segments
    p = feature_removal_path({ "subproject" => "playbook", "feature" => "revenue_business_line" }, "/process")
    assert_equal "/dev/feature-removals/playbook/revenue_business_line/process", p
  end

  # ---------- output ----------

  # `release` runs this reconciler unattended, so its lines land in the middle of
  # release output with nothing naming them. The header is what says which sweep
  # the "waiting"/"processed" lines belong to.
  def test_reconcile_titles_its_output
    out, = capture_io do
      with_stubbed_api("GET /dev/feature-removals?processed=false&limit=100" => [removal(apps: [])],
                       "GET /dev/feature-removals?processed=true&limit=100" => []) do
        cmd_features_reconcile([])
      end
    end
    assert_match(/^Feature-flag removals awaiting cleanup\b/, out)
    assert_match(/^  waiting  playbook\/revenue_business_line/, out)
  end

  # Nothing outstanding is the normal state between releases. A header plus
  # "0 processed, 0 purged, 0 outstanding" is a whole section saying nothing, in
  # the middle of release output — so the sweep stays silent instead.
  def test_reconcile_prints_nothing_when_there_is_nothing_to_do
    out, = capture_io do
      with_stubbed_api("GET /dev/feature-removals?processed=false&limit=100" => [],
                       "GET /dev/feature-removals?processed=true&limit=100" => []) do
        cmd_features_reconcile([])
      end
    end
    assert_equal "", out
  end

  # ---------- the ops close-out contract (ISS-815) ----------

  # The two silences mean opposite things, and this is the pair that pins it.
  #
  # In a RELEASE, "nothing to do" is the normal state and a section saying so is
  # noise — the test above. To an ops SESSION, whose entire deliverable is having
  # run this, "0 processed" is the answer and no line at all is indistinguishable
  # from a reconcile that never ran — which on a producer-filed issue is an
  # outcome of `dismissed` (ISS-809's failure mode, one level up).
  def test_under_an_ops_run_the_reconciler_reports_its_counts_even_when_nothing_moved
    out, = capture_io do
      with_ops_run do
        with_stubbed_api("GET /dev/feature-removals?processed=false&limit=100" => [],
                         "GET /dev/feature-removals?processed=true&limit=100" => []) do
          cmd_features_reconcile([])
        end
      end
    end
    report, visible = Agent::Ops.extract(out)
    assert_equal "nothing to process or purge; 0 outstanding.", report["summary"]
    assert_equal 0, report["effects"]["processed"]
    assert_equal "", visible, "the release log is unchanged; the marker is addressed to `run-op`"
  end

  def test_under_an_ops_run_the_reconciler_reports_what_it_moved
    purgeable = removal(apps: []).merge("processed_at" => "2026-01-01T12:00:00Z")
    out, = capture_io do
      with_ops_run do
        with_stubbed_api("GET /dev/feature-removals?processed=false&limit=100" => [],
                         "GET /dev/feature-removals?processed=true&limit=100" => [purgeable],
                         "POST /dev/feature-removals/playbook/revenue_business_line/purge" => {}) do
          cmd_features_reconcile(["--apply"])
        end
      end
    end
    report, = Agent::Ops.extract(out)
    assert_equal 1, report["effects"]["purged"]
    assert_equal true, report["effects"]["applied"]
    assert_match(/1 purged/, report["summary"])
  end

  def with_ops_run
    original = ENV[Agent::Ops::LISTENER_ENV]
    ENV[Agent::Ops::LISTENER_ENV] = "1"
    yield
  ensure
    ENV[Agent::Ops::LISTENER_ENV] = original
  end

  # ---------- features_reconcile_summary ----------

  def test_summary_is_omitted_when_nothing_moved
    assert_nil features_reconcile_summary(processed: 0, purged: 0, outstanding: 0, apply: true)
    # Still nil with removals outstanding: the per-removal "waiting" lines above
    # already say which ones and what they are waiting on.
    assert_nil features_reconcile_summary(processed: 0, purged: 0, outstanding: 3, apply: true)
  end

  def test_summary_counts_when_something_moved
    assert_equal "2 processed, 1 purged, 5 outstanding.",
                 features_reconcile_summary(processed: 2, purged: 1, outstanding: 5, apply: true)
  end

  def test_summary_is_conditional_in_dry_run
    assert_equal "2 would process, 0 would purge, 5 outstanding.",
                 features_reconcile_summary(processed: 2, purged: 0, outstanding: 5, apply: false)
  end
end
