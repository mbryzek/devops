require 'date'
require 'time'
require 'newrelic'

# What this account ingests into NewRelic, against the 100 GB free-tier ceiling
# (ISS-1077).
#
# WHY THIS EXISTS. Nothing watched the number. The account has a hard-ish free
# limit and no alert on it, so the first thing that would have said "you are over
# it" is an invoice or a throttle — and a throttle on the observability system is
# the failure that arrives disguised as every other failure. ISS-1070 then added
# two more reporting applications (acumen-web, acumen-job), each with its own
# per-app ingest FLOOR, on top of an account already at 73.5 GB of 100 in July.
#
# WHAT THE MEASUREMENT FOUND, 2026-08-08, and why the trend matters more than the
# question that prompted it. Ingest per calendar month:
#
#   Mar 51.6   Apr 51.5   May 60.6   Jun 61.6   Jul 73.5
#
# That is roughly +5 GB/month, on THREE services, with acumen not yet reporting
# at all. The original issue framed this as "does acumen fit"; the honest reading
# of the history is that platform alone reaches 100 GB around November whether or
# not acumen ever lands. So this is not an acumen question with a one-time
# answer, it is a standing measurement — which is what makes a command plus a
# daily check the right artifact rather than a number written into a document.
#
# THE BILLING PERIOD IS THE CALENDAR MONTH, IN UTC, AND THAT WAS WORTH CHECKING.
# Read with `SINCE 120 days ago TIMESERIES 1 day`, NrMTDConsumption appears to
# reset on the 30th or 31st — because now-anchored daily buckets straddle
# midnight, so the bucket LABELLED 07-31 spans 07-31T13:xx..08-01T13:xx and its
# `latest()` is already the new period. Pinned with explicit windows, the reset
# lands between 2026-08-01T00:00Z and T04:30Z. A projection built on the
# apparent boundary would have been wrong by a day at exactly the point in the
# month where being wrong costs the most.
module NewrelicIngest
  # `sum(GigabytesIngested)` over a window IS the ingest in that window; the
  # `DataPlatform` product line is the ingest half of NrConsumption (the rest is
  # seats and compute, which have their own free limits and are not at risk here
  # — FullPlatformUsers has sat at 1 of 1 free with 0 billable throughout).
  DATA_PLATFORM = "productLine = 'DataPlatform'".freeze

  # The run rate excludes TODAY. NrConsumption's current day is partial and
  # arrives late, so including it drags the average down by however far through
  # the day the check happens to run — a projection that reads lower at 6am than
  # at 6pm is one nobody trusts twice.
  RUN_RATE_DAYS = 7

  # Per-app ingest is `bytecountestimate()`, which is an ESTIMATE over the raw
  # events and does NOT reconcile to the billed figure: it misses what NewRelic
  # bills for and cannot be attributed to an app (k8s log forwarding arrives with
  # no appName — 1.2 GB/7d of it), and it counts bytes on disk rather than bytes
  # billed. It is here to answer "WHICH app moved", never "how much do we owe".
  # Every render says so, because a number that looks authoritative and is not is
  # worse than no number.
  APP_EVENT_TYPES = "Metric, Span, Log, Transaction, TransactionError".freeze

  # How far back the monthly history goes. Six months is enough to see a trend
  # and short enough that a plan change a year ago does not distort it.
  HISTORY_DAYS = 150

  # Fraction of the free limit at which the projection is worth an issue.
  #
  # 0.85 and not 1.0 deliberately. A check that only fires once the projection
  # crosses the ceiling fires in the last week of the month it is already too
  # late to change — every lever here (drop span events, sample log forwarding,
  # trim a service) works by reducing what is ingested FROM NOW ON, and none of
  # them refund what the month has already spent. August 2026 projects ~88 GB,
  # which is exactly the case this threshold exists to surface: not over, not
  # fine, and worth a decision made deliberately rather than by default.
  AT_RISK_FRACTION = 0.85

  Measurement = Struct.new(
    :at, :account_id, :mtd_gb, :free_limit_gb, :run_rate_gb_per_day, :trailing_30d_gb,
    :by_usage_metric, :by_app_gb_per_day, :history_gb, :unattributed_gb_per_day,
    keyword_init: true,
  ) do
    def period_start = Time.utc(at.utc.year, at.utc.month, 1)
    def period_days  = Date.new(at.utc.year, at.utc.month, -1).day
    def period_key   = at.utc.strftime("%Y-%m")
    def period_label = at.utc.strftime("%B %Y")

    # Fractional on purpose: on the 8th at 13:40 UTC this is 7.57 days, and
    # rounding it to 7 or 8 moves the projection by a full GB.
    def elapsed_days   = (at.utc - period_start) / 86_400.0
    def remaining_days = [period_days - elapsed_days, 0.0].max

    # What the month lands at if the last #{RUN_RATE_DAYS} days keep repeating.
    # Deliberately NOT `mtd / elapsed * period_days`: that spreads a step change
    # (a new application starting to report) backwards over days it did not
    # happen in, which understates exactly the event this check exists to catch.
    def projected_gb = mtd_gb + (run_rate_gb_per_day * remaining_days)

    def free_tier? = !free_limit_gb.nil? && free_limit_gb.positive?
    def fraction   = free_tier? ? projected_gb / free_limit_gb : nil
    def headroom_gb = free_tier? ? free_limit_gb - projected_gb : nil

    # :no_free_tier is not a failure — it is the account having moved onto a paid
    # plan, at which point a free-limit alarm is noise and the right behaviour is
    # to say so and file nothing.
    def verdict
      return :no_free_tier unless free_tier?
      return :over if projected_gb >= free_limit_gb || mtd_gb >= free_limit_gb
      return :at_risk if projected_gb >= free_limit_gb * AT_RISK_FRACTION

      :ok
    end

    def actionable? = %i[over at_risk].include?(verdict)

    # Month-scoped, so one issue per month per verdict for the whole fleet: the
    # platform will not re-file while a non-terminal issue with this fingerprint
    # exists, which is what lets every runner run this check independently
    # without N runners filing N issues. An escalation from `at_risk` to `over`
    # inside one month is a genuinely different finding and correctly files its
    # own, which is why the verdict is part of the key and the projection is not
    # — keying on the number would file a fresh issue every time it moved 0.1 GB.
    def fingerprint = "newrelic-ingest:#{period_key}:#{verdict}"

    def to_h
      {
        "at" => at.utc.iso8601, "account_id" => account_id, "period" => period_key,
        "mtd_gb" => mtd_gb, "free_limit_gb" => free_limit_gb,
        "run_rate_gb_per_day" => run_rate_gb_per_day, "projected_gb" => projected_gb,
        "headroom_gb" => headroom_gb, "trailing_30d_gb" => trailing_30d_gb,
        "verdict" => verdict.to_s, "by_usage_metric" => by_usage_metric,
        "by_app_gb_per_day" => by_app_gb_per_day,
        "unattributed_gb_per_day" => unattributed_gb_per_day, "history_gb" => history_gb,
      }
    end
  end

  module_function

  def queries
    {
      # `latest`, not `max`: the authoritative current figure for THIS period.
      mtd: "SELECT latest(consumption), latest(freeLimit) FROM NrMTDConsumption " \
           "WHERE metric = 'GigabytesIngested' SINCE 1 day ago",
      # Boundary-free, and the number to quote when someone asks "are we near
      # 100 GB a month" without wanting a lecture about billing periods.
      trailing: "SELECT sum(GigabytesIngested) FROM NrConsumption WHERE #{DATA_PLATFORM} SINCE 30 days ago",
      usage: "SELECT sum(GigabytesIngested) FROM NrConsumption WHERE #{DATA_PLATFORM} " \
             "SINCE 30 days ago FACET usageMetric",
      run_rate: "SELECT sum(GigabytesIngested) FROM NrConsumption WHERE #{DATA_PLATFORM} " \
                "SINCE #{RUN_RATE_DAYS + 1} days ago UNTIL 1 day ago",
      apps: "SELECT bytecountestimate()/1e9 FROM #{APP_EVENT_TYPES} SINCE #{RUN_RATE_DAYS} days ago " \
            "FACET appName LIMIT 50",
      # The unattributed slice is a SUBTRACTION and not a facet, because `FACET
      # appName` silently DROPS every row whose appName is null rather than
      # bucketing them under one. Measured 2026-08-08: the faceted query returns
      # 19.17 GB/7d across two apps and the same window unfaceted is 20.50 —
      # the missing 1.33 GB is k8s log forwarding, the third largest line in the
      # account, and a per-app table built from the facet alone reports it as
      # zero. That is the exact shape of quietly-wrong this file objects to, and
      # it was caught only by cross-checking the two.
      apps_total: "SELECT bytecountestimate()/1e9 FROM #{APP_EVENT_TYPES} SINCE #{RUN_RATE_DAYS} days ago",
      history: "SELECT max(consumption) FROM NrMTDConsumption WHERE metric = 'GigabytesIngested' " \
               "SINCE #{HISTORY_DAYS} days ago FACET monthOf(timestamp)",
    }
  end

  def measure(key:, account_id: Newrelic::ACCOUNT_ID, now: Time.now, http: nil)
    rows = Newrelic.nrql_all(queries, key: key, account_id: account_id, http: http)
    apps = app_totals(rows.fetch(:apps), number(rows.fetch(:apps_total).first, "bytecountestimate/1.0e9"))

    Measurement.new(
      at: now, account_id: account_id,
      mtd_gb: number(rows.fetch(:mtd).first, "latest.consumption"),
      free_limit_gb: number(rows.fetch(:mtd).first, "latest.freeLimit"),
      run_rate_gb_per_day: number(rows.fetch(:run_rate).first, "sum.GigabytesIngested") / RUN_RATE_DAYS.to_f,
      trailing_30d_gb: number(rows.fetch(:trailing).first, "sum.GigabytesIngested"),
      by_usage_metric: facet_totals(rows.fetch(:usage), "sum.GigabytesIngested"),
      by_app_gb_per_day: apps.fetch(:by_app),
      unattributed_gb_per_day: apps.fetch(:unattributed),
      history_gb: history(rows.fetch(:history)),
    )
  end

  # nil is 0.0 and not an exception: NRQL answers an empty window with a row
  # whose aggregate is null, and "no ingest in the last 7 days" is a real state
  # (a brand new account, an outage) that must not crash the tick.
  def number(row, field) = (row && row[field]).to_f

  def facet_totals(rows, field)
    rows.to_h { |row| [row["facet"].to_s, row[field].to_f] }
         .sort_by { |_name, gb| -gb }.to_h
  end

  # Splits the per-app estimate into what NewRelic could attribute to an
  # application and what it could not — the latter by subtracting the former
  # from the same window measured unfaceted. See the `apps_total` query for why
  # this cannot be a facet.
  #
  # Clamped at zero rather than allowed to go negative. The two queries are
  # separate reads of an ESTIMATE over slightly different moments, so a tiny
  # negative is a rounding artifact and not a discovery; printing one would
  # invite exactly the wrong conclusion about a number already labelled as
  # approximate.
  def app_totals(rows, total_gb)
    per_day = ->(gb) { gb / RUN_RATE_DAYS.to_f }
    attributed = rows.reject { |row| row["appName"].to_s.empty? }
    {
      by_app: attributed.to_h { |row| [row["appName"].to_s, per_day.call(row["bytecountestimate/1.0e9"].to_f)] }
                        .sort_by { |_name, gb| -gb }.to_h,
      unattributed: [per_day.call(total_gb - attributed.sum { |row| row["bytecountestimate/1.0e9"].to_f }), 0.0].max,
    }
  end

  # `monthOf(timestamp)` faceting gives "August 2026" in NewRelic's own English,
  # in no defined order. Parsed back to a sortable key rather than trusted,
  # because a history printed out of order reads as noise and the trend IS the
  # finding here. A facet that does not parse is dropped rather than guessed at.
  def history(rows)
    rows.filter_map { |row|
      month, year = row["facet"].to_s.split(" ")
      index = Date::MONTHNAMES.index(month)
      next if index.nil? || year.to_s !~ /\A\d{4}\z/

      [format("%04d-%02d", year.to_i, index), row["max.consumption"].to_f]
    }.sort.to_h
  end

  # ---- what a human, or an issue, is told ----

  def gb(value) = format("%.1f GB", value)

  # The current month is a PARTIAL total and every render marks it. An unmarked
  # 21.4 sitting under a 73.5 reads as a collapse in usage rather than as eight
  # days of it, which is the opposite of the conclusion the row supports.
  def history_lines(measurement)
    measurement.history_gb.map do |month, total|
      partial = month == measurement.period_key
      "  #{month}  #{format('%6.1f', total)} GB#{partial ? "   (month to date, #{format('%.1f', measurement.elapsed_days)} of #{measurement.period_days} days)" : ''}"
    end
  end

  VERDICT_SUMMARY = {
    over: "OVER — this month is projected to exceed the free tier",
    at_risk: "AT RISK — this month is projected within #{((1 - AT_RISK_FRACTION) * 100).round}% of the free tier",
    ok: "ok",
    no_free_tier: "no free tier on this account — nothing to measure against",
  }.freeze

  def text_report(measurement)
    lines = ["NewRelic data ingest — account #{measurement.account_id}, #{measurement.period_label}", ""]
    lines << "  #{VERDICT_SUMMARY.fetch(measurement.verdict)}"
    lines << ""
    lines << "  month to date       #{gb(measurement.mtd_gb)}#{measurement.free_tier? ? " of #{gb(measurement.free_limit_gb)} free" : ''}"
    lines << "  run rate            #{format('%.2f', measurement.run_rate_gb_per_day)} GB/day (last #{RUN_RATE_DAYS} full days)"
    lines << "  projected month end #{gb(measurement.projected_gb)}#{measurement.free_tier? ? " (#{(measurement.fraction * 100).round}% of free, #{gb(measurement.headroom_gb)} headroom)" : ''}"
    lines << "  trailing 30 days    #{gb(measurement.trailing_30d_gb)}   (billing-period independent)"
    lines += ["", "By usage metric, trailing 30 days:"]
    lines += measurement.by_usage_metric.map { |name, total| "  #{name.ljust(18)} #{format('%6.1f', total)} GB" }
    lines += ["", "By application, last #{RUN_RATE_DAYS} days (bytecountestimate — attribution, NOT the billed figure):"]
    lines += measurement.by_app_gb_per_day.map { |name, rate| "  #{name.ljust(18)} #{format('%6.2f', rate)} GB/day" }
    lines << "  #{'(no appName)'.ljust(18)} #{format('%6.2f', measurement.unattributed_gb_per_day)} GB/day   k8s log forwarding and anything else NewRelic cannot attribute"
    lines += ["", "Per calendar month (the billing period is the calendar month, UTC):"]
    lines += history_lines(measurement)
    lines.join("\n")
  end

  def issue_title(measurement)
    verb = measurement.verdict == :over ? "is projected to EXCEED" : "is projected to reach"
    "NewRelic ingest #{verb} the #{gb(measurement.free_limit_gb)} free tier in #{measurement.period_label} " \
      "(#{gb(measurement.projected_gb)})"
  end

  # Written to be decidable without opening NewRelic: the projection, what is
  # driving it, and the levers with their real sizes attached. The levers are
  # deliberately phrased as a CHOICE including "accept it" — an overage of a few
  # GB is a few dollars a month, and the failure this check exists to prevent is
  # not spending money, it is spending it without anyone deciding to.
  def issue_body(measurement)
    largest_metric, largest_metric_gb = measurement.by_usage_metric.first
    largest_app, largest_app_rate = measurement.by_app_gb_per_day.first

    lines = [
      "`dev newrelic ingest` projects **#{gb(measurement.projected_gb)}** for #{measurement.period_label} " \
      "against a #{gb(measurement.free_limit_gb)} free limit " \
      "(#{(measurement.fraction * 100).round}%, #{gb(measurement.headroom_gb)} headroom).",
      "",
      "- month to date: #{gb(measurement.mtd_gb)} over #{format('%.1f', measurement.elapsed_days)} of " \
      "#{measurement.period_days} days",
      "- run rate: #{format('%.2f', measurement.run_rate_gb_per_day)} GB/day over the last #{RUN_RATE_DAYS} full days",
      "- trailing 30 days: #{gb(measurement.trailing_30d_gb)} (independent of the billing boundary)",
      "",
      "Per calendar month:",
      "",
      "```",
      *history_lines(measurement),
      "```",
      "",
      "Largest component: **#{largest_metric}** at #{gb(largest_metric_gb)} of the trailing 30 days. " \
      "Largest application: **#{largest_app}** at #{format('%.2f', largest_app_rate)} GB/day " \
      "(bytecountestimate — attribution only, it does not reconcile to the billed figure).",
      "",
      "## Decide, rather than let it happen",
      "",
      "Every lever works on what is ingested FROM NOW ON; none refunds what the month has already spent, " \
      "which is why this fires at #{(AT_RISK_FRACTION * 100).round}% rather than at the ceiling.",
      "",
      "- **Trim tracing.** Spans are usually the largest single line and the least read. " \
        "`newrelic.yml` `distributed_tracing.enabled: false` / `span_events.enabled: false` per app.",
      "- **Sample log forwarding.** `application_logging.forwarding.max_samples_stored`, and note the " \
        "unattributed #{format('%.2f', measurement.unattributed_gb_per_day)} GB/day above is k8s forwarding " \
        "that no per-app setting reaches.",
      "- **Drop an application's instrumentation** if it is reporting more than it is worth.",
      "- **Accept the overage.** At NewRelic's standard rate a few GB over is a few dollars a month. " \
        "This is a legitimate answer — it just has to be a decision.",
      "",
      "Re-measure at any time with `dev newrelic ingest` (`--json` for the raw figures). " \
      "This issue was filed by the daily check in `Agent::Tick#check_newrelic_ingest` (ISS-1077); it is " \
      "fingerprinted per month and per verdict, so it files once for the fleet and re-files if the " \
      "verdict escalates.",
    ]
    lines.join("\n")
  end
end
