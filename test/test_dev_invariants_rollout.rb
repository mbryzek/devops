#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The rollout guard (ISS-517): an invariant is SQL that ships inside the app and
# the check is answered by whichever replica the load balancer picks, so a result
# collected during a rolling deploy may have come from a pod running the previous
# release. ISS-509 was filed exactly that way.
#
# Everything here exercises the pure seams. `invariants_rollout_reason` takes its
# samples as an argument and `invariants_rollout_deferrals` takes its prober, so
# no test reaches /_internal_/version.
class TestDevInvariantsRollout < Minitest::Test
  include DevTestSupport

  NOW = Time.parse("2026-08-05T11:07:57Z").freeze

  def sample(version, released_at = nil)
    { "version" => version, "released_at" => released_at }.compact
  end

  def ago(secs) = (NOW - secs).utc.iso8601

  def endpoint(name, use_localhost: false)
    app = name.downcase
    ApiClient.endpoints(use_localhost: use_localhost, app_filter: app).first
  end

  def failing_data(name: "some_invariant", count: 1)
    {
      "success" => Array.new(59) { |i| { "name" => "ok_#{i}" } },
      "non_zero" => [{ "name" => name, "count" => count }],
      "error" => [],
    }
  end

  def passing_data
    { "success" => [{ "name" => "ok" }], "non_zero" => [], "error" => [] }
  end

  def result_for(name, data: nil, error: nil, use_localhost: false)
    { endpoint: endpoint(name, use_localhost: use_localhost), data: data, error: error }
  end

  def reason(samples, now: NOW)
    invariants_rollout_reason(samples, now: now)
  end

  # ---- invariants_rollout_reason: two versions at once is proof ----

  # The strong signal, and the reason one probe is not enough: during a rollout
  # the version endpoint is served by the same mixed fleet as the check, so a
  # single sample can report the OLD release and look perfectly settled.
  def test_two_versions_at_once_defers
    r = reason([sample("0.10.21", ago(4 * 3600)), sample("0.10.22", ago(198))])
    refute_nil r
    assert_includes r, "0.10.21 and 0.10.22"
    assert_includes r, "rollout is in progress"
  end

  # The guard turning into the outage: a StatefulSet will not delete a pod until
  # it is Ready, so one that crashlooped on an earlier release sits on the old
  # image indefinitely (lib/rollout_diagnosis.rb). Deferring on proof alone would
  # then defer forever and this app's invariants would silently never be filed
  # again. Past the window a mixed fleet is a STUCK rollout, and the failure is
  # filed so somebody looks at it.
  def test_a_stuck_fleet_is_filed_rather_than_deferred_forever
    assert_nil reason([sample("0.10.21", ago(9 * 3600)), sample("0.10.20", ago(30 * 3600))])
  end

  # A failed probe is not evidence of a second version. Counting `{error: ...}`
  # as one would report a rollout every time a single request timed out.
  def test_a_failed_probe_is_not_a_second_version
    r = reason([{ error: "HTTP 502" }, sample("0.10.21", ago(60))])
    refute_nil r
    refute_includes r, "at once"
  end

  def test_a_blank_version_is_not_a_second_version
    r = reason([sample("", ago(60)), sample("0.10.21", ago(60))])
    refute_nil r
    refute_includes r, "at once"
  end

  # ---- invariants_rollout_reason: the recency window ----

  # ISS-509's actual timings: 0.10.22 cut at 11:04:39Z, checked at 11:07:57Z.
  def test_a_release_inside_the_window_defers
    r = reason([sample("0.10.22", "2026-08-05T11:04:39Z")] * 5)
    refute_nil r
    assert_includes r, "0.10.22 was released 3 minutes ago"
  end

  def test_a_settled_release_does_not_defer
    assert_nil reason([sample("0.10.22", ago(4 * 3600))] * 5)
  end

  # The window is a floor, not a ceiling: at exactly 15 minutes the fleet is
  # considered settled, so the boundary cannot drift into deferring forever.
  def test_the_window_boundary_does_not_defer
    assert_nil reason([sample("0.10.22", ago(INVARIANTS_ROLLOUT_WINDOW_SECS))])
    refute_nil reason([sample("0.10.22", ago(INVARIANTS_ROLLOUT_WINDOW_SECS - 1))])
  end

  # A released_at in the future means clock skew between this box and the build,
  # and a build stamped ahead of us is a release that JUST happened. Deferring is
  # the safe reading; treating it as settled would reopen the exact race.
  def test_a_future_release_timestamp_defers
    refute_nil reason([sample("0.10.22", (NOW + 90).utc.iso8601)])
  end

  # ---- invariants_rollout_reason: fail open ----
  #
  # A guard that swallows real invariant failures whenever a probe breaks is
  # strictly worse than the bug it replaces, because nothing would surface it.

  def test_no_usable_samples_does_not_defer
    assert_nil reason([{ error: "timeout" }, { error: "HTTP 500" }])
    assert_nil reason([])
  end

  def test_a_missing_released_at_does_not_defer
    assert_nil reason([sample("0.10.22")] * 3)
  end

  def test_an_unparseable_released_at_does_not_defer
    assert_nil reason([sample("0.10.22", "not-a-date")] * 3)
  end

  # Even with proof of a mixed fleet: an undatable rollout is an unbounded
  # deferral, which is the one thing this guard must never be.
  def test_two_versions_with_no_usable_timestamp_does_not_defer
    assert_nil reason([sample("0.10.21"), sample("0.10.22")])
  end

  # ---- invariants_humanize_age ----

  def test_humanize_age
    assert_equal "less than a minute", invariants_humanize_age(20)
    assert_equal "1 minute", invariants_humanize_age(62)
    assert_equal "3 minutes", invariants_humanize_age(198)
  end

  # ---- invariants_rollout_deferrals: what gets probed at all ----

  def probe_recording(names, samples: [])
    ->(endpoint) { names << endpoint[:name]; samples }
  end

  def test_only_failing_apps_are_probed
    probed = []
    results = [result_for("Acumen", data: failing_data), result_for("Platform", data: passing_data)]
    invariants_rollout_deferrals(results, now: NOW, probe: probe_recording(probed))
    assert_equal ["Acumen"], probed
  end

  def test_an_unreachable_app_is_not_probed
    probed = []
    results = [result_for("Platform", error: "session expired")]
    assert_empty invariants_rollout_deferrals(results, now: NOW, probe: probe_recording(probed))
    assert_empty probed
  end

  # There is one local process and nothing rolls out; a dev restart would defer
  # for no reason.
  def test_localhost_is_never_deferred
    probed = []
    results = [result_for("Acumen", data: failing_data, use_localhost: true)]
    assert_empty invariants_rollout_deferrals(results, now: NOW, probe: probe_recording(probed))
    assert_empty probed
  end

  def test_deferrals_are_keyed_by_endpoint_name
    results = [result_for("Acumen", data: failing_data)]
    deferrals = invariants_rollout_deferrals(
      results, now: NOW, probe: probe_recording([], samples: [sample("0.10.22", ago(60))])
    )
    assert_equal ["Acumen"], deferrals.keys
    assert_includes deferrals["Acumen"], "0.10.22"
  end

  def test_a_settled_app_gets_no_deferral
    results = [result_for("Acumen", data: failing_data)]
    deferrals = invariants_rollout_deferrals(
      results, now: NOW, probe: probe_recording([], samples: [sample("0.10.22", ago(9 * 3600))])
    )
    assert_empty deferrals
  end

  # ---- the verdict: a deferred app is uncheckable, not a finding ----

  def deferred_results(*names)
    results = names.map { |n| result_for(n, data: failing_data) }
    invariants_apply_deferrals(results, names.to_h { |n| [n, "a rollout is in progress"] })
  end

  def test_apply_deferrals_only_marks_the_named_app
    results = [result_for("Acumen", data: failing_data), result_for("Platform", data: failing_data)]
    marked = invariants_apply_deferrals(results, { "Acumen" => "mid-rollout" })
    assert_equal "mid-rollout", marked.find { |r| r[:endpoint][:name] == "Acumen" }[:deferred]
    assert_nil marked.find { |r| r[:endpoint][:name] == "Platform" }[:deferred]
  end

  # The whole point: no issue is filed and no session is dispatched.
  def test_a_deferred_app_is_not_a_failing_app
    assert_empty invariants_failing_apps(deferred_results("Acumen"))
  end

  def test_a_deferred_app_exits_uncheckable_rather_than_findings
    assert_equal INVARIANTS_EXIT_UNCHECKABLE, invariants_exit_code(deferred_results("Acumen"))
  end

  # Deferral is per app. Platform failing while acumen rolls out still files.
  def test_a_settled_app_still_files_while_another_defers
    results = [result_for("Acumen", data: failing_data), result_for("Platform", data: failing_data)]
    marked = invariants_apply_deferrals(results, { "Acumen" => "mid-rollout" })
    assert_equal INVARIANTS_EXIT_FINDINGS, invariants_exit_code(marked)
    assert_equal ["Platform"], invariants_failing_apps(marked).map { |e, _| e[:name] }
  end

  # A pass is never deferred: the guard only ever delays a finding by one run.
  def test_a_clean_run_is_unaffected
    results = [result_for("Acumen", data: passing_data), result_for("Platform", data: passing_data)]
    marked = invariants_apply_deferrals(results, invariants_rollout_deferrals(results, now: NOW, probe: ->(_) { flunk "probed a passing app" }))
    assert_equal INVARIANTS_EXIT_CLEAN, invariants_exit_code(marked)
  end
end
