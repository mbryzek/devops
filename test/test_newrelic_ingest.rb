#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'newrelic'
require 'newrelic_ingest'
require 'agent/newrelic_watch'

# NewRelic ingest against the 100 GB free tier (ISS-1077).
#
# Almost every assertion here is about a number that could be QUIETLY WRONG
# rather than about one that could be missing, because that is the failure mode
# this feature has. An unauthenticated NerdGraph read returns `{"results": []}`
# with a 200; `FACET appName` silently omits the rows it cannot attribute; a
# now-anchored TIMESERIES makes the billing period look like it resets on the
# 31st. Each of those produces a plausible, confident, wrong answer, and a check
# nobody can trust is worse than no check — so each of them is pinned below.
class TestNewrelicIngest < Minitest::Test
  include DevTestSupport

  NI = NewrelicIngest

  # Every other suite gets NewrelicWatchGuard's "already measured today"
  # stand-in, so a tick test does not run a measurement it never asked for. This
  # file is ABOUT the cadence, so it opts out — safely, because every assertion
  # that touches the marker builds its own temp state dir and none of them read
  # the machine's.
  def before_setup
    super
    DevTestSupport::NewrelicWatchGuard.uninstall
  end

  # `at` is fixed to a real moment mid-month: 2026-08-08T13:40Z is 7.57 days into
  # a 31-day period, which is the case where rounding elapsed days to an integer
  # visibly moves the projection.
  NOW = Time.utc(2026, 8, 8, 13, 40, 0)

  # Every figure here is the real measurement taken on 2026-08-08, so a change in
  # the arithmetic shows up as a diff against a number that was actually true.
  #
  # Keyed by the name in `NewrelicIngest.queries` rather than by a fragment of
  # NRQL: two of those queries differ only by a trailing `FACET`, so fragment
  # matching turns a stub into a puzzle about escaping and substring precedence.
  # It also means a query renamed or added without a stub fails loudly here.
  def responses(mtd: 21.445098041, free_limit: 100.0, run_rate_total: 19.328824563,
                apps: [["platform-web", 15.086435705], ["platform-job", 4.082026792]],
                apps_total: 20.497435562)
    {
      mtd: [{ "latest.consumption" => mtd, "latest.freeLimit" => free_limit }],
      trailing: [{ "sum.GigabytesIngested" => 76.675622875 }],
      usage: [
        { "facet" => "MetricsBytes", "sum.GigabytesIngested" => 37.7116125 },
        { "facet" => "TracingBytes", "sum.GigabytesIngested" => 30.790549654 },
        { "facet" => "LoggingBytes", "sum.GigabytesIngested" => 4.503059749 },
        { "facet" => "ApmEventsBytes", "sum.GigabytesIngested" => 3.670400972 },
      ],
      run_rate: [{ "sum.GigabytesIngested" => run_rate_total }],
      apps: apps.map { |name, gb| { "facet" => name, "appName" => name, "bytecountestimate/1.0e9" => gb } },
      apps_total: [{ "bytecountestimate/1.0e9" => apps_total }],
      history: [
        # Deliberately out of order: NewRelic does not promise one, and the trend
        # is the whole finding.
        { "facet" => "July 2026", "max.consumption" => 73.5 },
        { "facet" => "March 2026", "max.consumption" => 51.567917904 },
        { "facet" => "August 2026", "max.consumption" => 21.445098041 },
        { "facet" => "June 2026", "max.consumption" => 61.55 },
        { "facet" => "April 2026", "max.consumption" => 51.54 },
        { "facet" => "May 2026", "max.consumption" => 60.55 },
      ],
    }
  end

  # Pulls the NRQL back out of the GraphQL body and reverse-maps it to the name
  # `NewrelicIngest.queries` gave it. Round-tripping through the real body is the
  # point: it exercises `graphql_body`'s escaping rather than assuming it.
  def stub_http(table)
    by_query = NI.queries.to_h { |name, query| [query, name] }
    lambda do |json, key|
      refute_empty key.to_s, "the client must never issue an unauthenticated request"
      nrql = JSON.parse(json).fetch("query")[/nrql\(query: "(.*)"\) \{ results \}/, 1]
      name = by_query.fetch(JSON.parse(%("#{nrql}")), nil)
      raise "no stub for #{nrql.inspect}" if name.nil?

      { "data" => { "actor" => { "account" => { "nrql" => { "results" => table.fetch(name) } } } } }
    end
  end

  def measure(**overrides)
    NI.measure(key: "NRAK-test", now: NOW, http: stub_http(responses(**overrides)))
  end

  # ---- the client refuses every shape of "answer that is not an answer" ----

  # The ISS-635 property, and the reason this client exists at all. An empty
  # result set is what an unauthenticated read returns AND what a healthy quiet
  # account returns, so the only safe moment to distinguish them is before the
  # request.
  def test_nrql_refuses_to_query_without_a_key
    error = assert_raises(Newrelic::Error) do
      Newrelic.nrql("SELECT 1 FROM Transaction", key: nil, http: ->(_json, _key) { flunk "must not reach the network" })
    end
    assert_includes error.message, "NEWRELIC_USER_KEY"
    assert_includes error.message, "ISS-635"
  end

  def test_nrql_raises_on_graphql_errors_even_with_a_200
    http = ->(_json, _key) { { "errors" => [{ "message" => "API key is invalid" }] } }
    error = assert_raises(Newrelic::Error) { Newrelic.nrql("SELECT 1 FROM Transaction", key: "k", http: http) }
    assert_includes error.message, "API key is invalid"
  end

  # The distinction the whole module turns on: a body we do not understand must
  # not degrade to "no rows", because "no rows" is data a caller will act on.
  def test_nrql_raises_rather_than_inventing_an_empty_result
    http = ->(_json, _key) { { "data" => { "actor" => { "account" => {} } } } }
    assert_raises(Newrelic::Error) { Newrelic.nrql("SELECT 1 FROM Transaction", key: "k", http: http) }
  end

  def test_nrql_returns_empty_only_for_a_genuinely_empty_result
    http = ->(_json, _key) { { "data" => { "actor" => { "account" => { "nrql" => { "results" => [] } } } } } }
    assert_equal [], Newrelic.nrql("SELECT 1 FROM Transaction", key: "k", http: http)
  end

  # The daily check lives in `Agent::Tick#phase_b`, so without a guard on this
  # client every tick test in the suite sent a real request to api.newrelic.com.
  # It did not turn the suite red — the check rescues `Newrelic::Error` so a
  # NewRelic outage cannot break a runner's work phase — so the live 401s showed
  # up only as thread backtraces in the middle of a passing run.
  def test_the_suite_cannot_reach_nerdgraph_without_the_seam
    error = assert_raises(DevTestSupport::NetworkBlocked) do
      Newrelic.nrql("SELECT 1 FROM Transaction", key: "NRAK-test")
    end
    assert_includes error.message, "http:"
  end

  # The tick contains this client with a single `rescue Newrelic::Error`, which
  # only works if there is one error type. Net::HTTP raises SocketError on a DNS
  # failure and Net::OpenTimeout on an unreachable host; unwrapped, those reach
  # phase_b's StandardError backstop as a WORK PHASE CRASH — on every runner at
  # once, blaming each machine for a third party being down, and skipping that
  # tick's reap and claim to do it.
  def test_transport_failures_are_reported_as_newrelic_errors
    [SocketError.new("getaddrinfo: nodename nor servname provided"),
     Net::OpenTimeout.new("execution expired"),
     Errno::ECONNRESET.new,
     OpenSSL::SSL::SSLError.new("handshake failure")].each do |raised|
      error = assert_raises(Newrelic::Error, "#{raised.class} must be contained") do
        Newrelic.post("{}", key: "k", http: ->(_json, _key) { raise raised })
      end
      assert_includes error.message, "unreachable"
    end
  end

  # A failure in one of several concurrent queries has to reach the caller rather
  # than leaving a measurement with a hole in it — and must not ALSO dump a
  # backtrace per thread into launchd's log for a condition the tick treats as
  # unremarkable.
  def test_a_failing_query_propagates_without_reporting_itself_to_stderr
    stderr = StringIO.new
    original = $stderr
    $stderr = stderr
    begin
      assert_raises(Newrelic::Error) do
        Newrelic.nrql_all({ a: "SELECT 1", b: "SELECT 2" }, key: "k",
                          http: ->(_json, _key) { raise Newrelic::Error, "boom" })
      end
    ensure
      $stderr = original
    end
    assert_empty stderr.string
  end

  def test_account_id_is_interpolated_as_an_integer
    assert_includes Newrelic.graphql_body("SELECT 1", 7724695), "account(id: 7724695)"
    assert_raises(ArgumentError) { Newrelic.graphql_body("SELECT 1", "7724695; DROP") }
  end

  # ---- the period, which is the thing that looked obvious and was not ----

  # Read with a now-anchored `TIMESERIES 1 day`, NrMTDConsumption appears to reset
  # on the 30th or 31st. Pinned with explicit windows it resets just after
  # 00:00 UTC on the 1st. If this ever flips back to the apparent boundary, the
  # projection is wrong by a day at the point in the month it matters most.
  def test_period_is_the_calendar_month_in_utc
    m = measure
    assert_equal Time.utc(2026, 8, 1), m.period_start
    assert_equal 31, m.period_days
    assert_equal "2026-08", m.period_key
  end

  def test_elapsed_days_is_fractional
    assert_in_delta 7.569, measure.elapsed_days, 0.001
    assert_in_delta 23.431, measure.remaining_days, 0.001
  end

  # Not `mtd / elapsed * period_days`. That formula spreads a step change
  # backwards over days it did not happen in, which understates exactly the event
  # this check exists to catch — a new application starting to report.
  def test_projection_extends_the_recent_run_rate_over_the_days_that_remain
    m = measure
    assert_in_delta 2.761, m.run_rate_gb_per_day, 0.001
    assert_in_delta 86.14, m.projected_gb, 0.01
    assert_in_delta 13.86, m.headroom_gb, 0.01
  end

  def test_remaining_days_never_goes_negative
    m = NI.measure(key: "k", now: Time.utc(2026, 8, 31, 23, 59), http: stub_http(responses))
    assert_operator m.remaining_days, :>=, 0.0
    assert_operator m.projected_gb, :>=, m.mtd_gb
  end

  # ---- the verdict ----

  # August 2026 is the case the threshold was chosen for: not over, not fine.
  def test_the_real_august_measurement_is_at_risk
    assert_equal :at_risk, measure.verdict
    assert measure.actionable?
  end

  def test_verdict_is_ok_below_the_threshold
    assert_equal :ok, measure(run_rate_total: 7.0).verdict
    refute measure(run_rate_total: 7.0).actionable?
  end

  def test_verdict_is_over_when_the_projection_crosses_the_limit
    assert_equal :over, measure(run_rate_total: 40.0).verdict
  end

  # An MTD already past the limit is `over` no matter what the run rate does
  # next — including a run rate that has since dropped to nothing.
  def test_verdict_is_over_when_the_month_has_already_spent_the_limit
    assert_equal :over, measure(mtd: 104.0, run_rate_total: 0.0).verdict
  end

  # A paid plan is not an alarm. `freeLimit` going to 0 means the free tier no
  # longer applies, and screaming about a ceiling that no longer exists is how a
  # check gets muted.
  def test_no_free_tier_is_a_verdict_and_not_an_alarm
    m = measure(free_limit: 0.0)
    assert_equal :no_free_tier, m.verdict
    refute m.actionable?
    assert_nil m.headroom_gb
  end

  # Month AND verdict, so one issue per month for the fleet, and an escalation
  # from at_risk to over inside a month is correctly a different finding. The
  # projection is deliberately NOT in the key — keying on it would file a fresh
  # issue every time the number moved 0.1 GB.
  def test_fingerprint_is_scoped_to_the_month_and_the_verdict
    assert_equal "newrelic-ingest:2026-08:at_risk", measure.fingerprint
    assert_equal "newrelic-ingest:2026-08:over", measure(run_rate_total: 40.0).fingerprint
    assert_equal measure.fingerprint, measure(run_rate_total: 19.4).fingerprint
  end

  # ---- attribution, and the row that a facet drops ----

  # `FACET appName` omits null-appName rows entirely rather than bucketing them.
  # Measured 2026-08-08: 19.17 GB/7d faceted against 20.50 unfaceted, and the
  # missing 1.33 GB is k8s log forwarding — the third largest line in the
  # account. A per-app table built from the facet alone reports it as zero.
  def test_unattributed_ingest_is_recovered_by_subtraction_not_by_faceting
    m = measure
    assert_equal %w[platform-web platform-job], m.by_app_gb_per_day.keys
    assert_in_delta 2.155, m.by_app_gb_per_day.fetch("platform-web"), 0.001
    assert_in_delta 0.190, m.unattributed_gb_per_day, 0.001
  end

  # Two separate reads of an estimate can disagree slightly. A tiny negative is a
  # rounding artifact, and printing one would invite a conclusion the number
  # cannot support.
  def test_unattributed_is_clamped_at_zero
    assert_equal 0.0, measure(apps_total: 1.0).unattributed_gb_per_day
  end

  def test_apps_are_ranked_largest_first
    m = measure(apps: [["small", 1.0], ["large", 9.0], ["middle", 4.0]], apps_total: 14.0)
    assert_equal %w[large middle small], m.by_app_gb_per_day.keys
  end

  # ---- history ----

  def test_history_is_parsed_out_of_newrelics_english_and_sorted
    assert_equal %w[2026-03 2026-04 2026-05 2026-06 2026-07 2026-08], measure.history_gb.keys
    assert_in_delta 73.5, measure.history_gb.fetch("2026-07"), 0.01
  end

  # A facet that does not parse is dropped rather than guessed at — an unsorted
  # or misplaced row would misrepresent the trend, which is the finding.
  def test_history_drops_facets_it_cannot_parse
    parsed = NI.history([{ "facet" => "Smarch 2026", "max.consumption" => 1.0 },
                         { "facet" => "totally bogus", "max.consumption" => 2.0 },
                         { "facet" => "May 2026", "max.consumption" => 60.55 }])
    assert_equal %w[2026-05], parsed.keys
  end

  # The current month is a PARTIAL total. Unmarked, a 21.4 under a 73.5 reads as
  # a collapse in usage rather than as eight days of it.
  def test_the_partial_current_month_is_marked_as_such
    lines = NI.history_lines(measure)
    assert_match(/2026-07\s+73\.5 GB\z/, lines[4])
    assert_includes lines[5], "month to date, 7.6 of 31 days"
  end

  # ---- what a human, or an issue, is told ----

  def test_text_report_labels_the_per_app_estimate_as_attribution_not_billing
    report = NI.text_report(measure)
    assert_includes report, "NOT the billed figure"
    assert_includes report, "projected month end 86.1 GB"
    assert_includes report, "trailing 30 days    76.7 GB"
    assert_includes report, "(no appName)"
  end

  def test_issue_body_carries_the_projection_the_trend_and_a_decision
    body = NI.issue_body(measure)
    assert_includes body, "86.1 GB"
    assert_includes body, "2026-07    73.5 GB"
    assert_includes body, "Accept the overage"
    assert_includes body, "dev newrelic ingest"
    # The levers only act on future ingest, which is why the threshold is below
    # the ceiling. If that sentence goes, the threshold looks arbitrary.
    assert_includes body, "none refunds what the month has already spent"
  end

  def test_issue_title_distinguishes_over_from_at_risk
    assert_includes NI.issue_title(measure), "is projected to reach"
    assert_includes NI.issue_title(measure(run_rate_total: 40.0)), "EXCEED"
  end

  # ---- the daily check's own state ----

  def with_state_dir
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_STATE_DIR"]
      ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
      begin
        yield
      ensure
        ENV["DEV_AGENT_STATE_DIR"] = original
      end
    end
  end

  # A machine that has never checked answers on its first tick rather than a day
  # later, which is what gives a freshly provisioned runner an answer at all.
  def test_a_machine_that_has_never_checked_is_due_immediately
    with_state_dir { assert Agent::NewrelicWatch.due?(now: NOW) }
  end

  def test_the_marker_throttles_to_a_daily_cadence
    with_state_dir do
      Agent::NewrelicWatch.record(measure, now: NOW)
      refute Agent::NewrelicWatch.due?(now: NOW + 3600)
      assert Agent::NewrelicWatch.due?(now: NOW + (25 * 3600))
    end
  end

  # "Ran and found nothing" and "never ran" are the same silence otherwise —
  # the failure ISS-531 is about. A pass that could not run stamps the marker
  # too, and says why.
  def test_a_pass_that_could_not_run_is_recorded_with_its_reason
    with_state_dir do
      Agent::NewrelicWatch.record(nil, now: NOW, skipped: "no NEWRELIC_USER_KEY")
      state = Agent::NewrelicWatch.state
      assert_equal "no NEWRELIC_USER_KEY", state.fetch("skipped")
      refute Agent::NewrelicWatch.due?(now: NOW + 3600)
      refute state.key?("verdict")
    end
  end

  def test_the_marker_records_what_a_clean_pass_found
    with_state_dir do
      Agent::NewrelicWatch.record(measure, now: NOW)
      state = Agent::NewrelicWatch.state
      assert_equal "at_risk", state.fetch("verdict")
      assert_in_delta 86.14, state.fetch("projected_gb"), 0.01
      refute state.key?("skipped")
    end
  end

  # The credential is read through the same probe a spawned session's is, so
  # `dev newrelic ingest` and the tick cannot disagree about what this machine
  # has. The suite-wide CredentialsGuard reports every credential present with a
  # fake value, which is the right default everywhere else and is exactly what
  # these two assertions are about — so they opt out, the way
  # test_dev_agent_toolchain.rb opts out of ToolchainGuard.
  def test_key_returns_the_resolved_value
    DevTestSupport::CredentialsGuard.uninstall
    # The process environment short-circuits before the env repo is consulted,
    # so this is deterministic on a machine that has a real env repo and on one
    # that does not.
    assert_equal "NRAK-from-env", Agent::NewrelicWatch.key(env: { "NEWRELIC_USER_KEY" => "NRAK-from-env" })
  ensure
    DevTestSupport::CredentialsGuard.install
  end

  # nil and not "" — the client branches on empty-vs-nil nowhere, but the tick
  # branches on nil to decide between measuring and recording a skip, and a
  # falsy-but-present value would send it to NerdGraph unauthenticated.
  def test_key_is_nil_when_the_credential_does_not_resolve
    saved = Agent::Credentials.method(:probe)
    Agent::Credentials.define_singleton_method(:probe) { |_credential, **_opts| [:missing, nil, nil] }
    assert_nil Agent::NewrelicWatch.key
  ensure
    Agent::Credentials.define_singleton_method(:probe, saved)
  end
end
