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
    # Stub the per-app lookup rather than the registry: fetch_app_version is the
    # shared probe and is covered by the deploy tests.
    orig = method(:feature_version_info)
    define_singleton_method(:feature_version_info) { |_r, _c, app| versions[app] }
    begin
      feature_removal_state(registry, cache, rem)
    ensure
      define_singleton_method(:feature_version_info, orig)
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

  # ---------- paths ----------

  def test_feature_removal_path_encodes_both_segments
    p = feature_removal_path({ "subproject" => "playbook", "feature" => "revenue_business_line" }, "/process")
    assert_equal "/dev/feature-removals/playbook/revenue_business_line/process", p
  end
end
