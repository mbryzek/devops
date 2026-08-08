#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers how `dev queries top` renders the statement under each ranked row.
#
# The statement is the actionable half of the output — the ranking says a query is
# expensive, the SQL says which one and why — so it is capped generously and wrapped
# to the terminal rather than emitted as one line the terminal folds mid-token.
class TestDevQueries < Minitest::Test
  INDENT = "  ".freeze

  def lines(sql, width: 60)
    with_terminal_width(width) { queries_sql_lines(sql, indent: INDENT) }
  end

  # queries_sql_lines asks the terminal for its width; stub it so the wrap point is
  # the test's, not the width of whatever terminal happens to run the suite.
  def with_terminal_width(width)
    original = method(:terminal_width)
    Object.send(:define_method, :terminal_width) { width }
    yield
  ensure
    Object.send(:define_method, :terminal_width, original)
  end

  def body(rendered) = rendered.map { |l| l.sub(/\A#{INDENT}/, "") }.join(" ")

  def test_short_statement_is_one_indented_line
    assert_equal ["#{INDENT}select 1 from tasks"], lines("select 1 from tasks")
  end

  def test_collapses_whitespace
    assert_equal ["#{INDENT}select id from tasks"], lines("select  id\n  from\ttasks\n")
  end

  def test_wraps_to_the_available_width
    rendered = lines("select #{(1..30).map { |i| "column_#{i}" }.join(', ')} from tasks", width: 80)
    assert rendered.length > 1, "expected the statement to wrap across lines"
    rendered.each { |l| assert_operator l.length, :<=, 80, "line exceeds terminal width: #{l.inspect}" }
    assert rendered.all? { |l| l.start_with?(INDENT) }, "every line is indented under its row"
  end

  # The cap is what the row is allowed to show; beyond it the tail is elided rather
  # than allowed to bury the ranking.
  def test_caps_the_total_characters_shown
    sql = "select #{(1..200).map { |i| "column_#{i}" }.join(', ')} from tasks"
    assert_operator sql.length, :>, QUERIES_SQL_CHARS
    shown = body(lines(sql, width: 100))
    assert_equal QUERIES_SQL_CHARS, shown.length
    assert shown.end_with?("..."), "an elided statement says so"
    assert sql.start_with?(shown[0, QUERIES_SQL_CHARS - 3]), "the head shown is the statement's own head"
  end

  # A single token longer than the line has no word boundary to break on; it must
  # still be emitted rather than loop or overflow.
  def test_hard_splits_a_token_wider_than_the_line
    rendered = lines("x" * 200, width: 100)
    rendered.each { |l| assert_operator l.length, :<=, 100 }
    assert_equal "x" * 200, rendered.map { |l| l.sub(/\A#{INDENT}/, "") }.join
  end

  # Wrapping is presentation only: nothing may be dropped between the words.
  def test_preserves_the_statement_across_wrapped_lines
    sql = "select #{(1..20).map { |i| "col_#{i}" }.join(', ')} from playbook.members where club_id = ?"
    assert_equal sql, body(lines(sql, width: 50))
  end
end

# Covers the offer to investigate that follows the ranking: which queries the
# prompt turns into an issue, and what that issue says.
#
# The body is a prompt for a session that has no context but this issue, so the
# assertions are about it being self-contained — the code paths named, and the
# three ways a naive reading of these numbers goes wrong (first-statement
# attribution, normalized binds, sums across nodes) spelled out.
class TestDevQueriesInvestigate < Minitest::Test
  include DevTestSupport

  DAO_SITE = "generated.db.playbook.BaseMemberEngagementScoresDao.findAll(MemberEngagementScoresDao.scala:242)".freeze

  def stat(sql: "select id from playbook.members where club_id = ?", call_site: DAO_SITE,
           total_ms: 67757, calls: 1348, mean_ms: 50, max_ms: 255, multi_statement_calls: 0,
           id: "qs-1f0e", sample_count: 3,
           first_sample_at: "2026-08-05T00:00:00.000Z", last_sample_at: "2026-08-06T12:00:00.000Z")
    { "id" => id, "sql" => sql, "call_site" => call_site, "total_ms" => total_ms,
      "calls" => calls, "mean_ms" => mean_ms, "max_ms" => max_ms,
      "multi_statement_calls" => multi_statement_calls, "sample_count" => sample_count,
      "first_sample_at" => first_sample_at, "last_sample_at" => last_sample_at }
  end

  # Drive the prompt with a canned answer and a stubbed tty, and record whether
  # anything was filed. Returns the form passed to the filing helper, or nil.
  # The offer only asks $stdin whether it is a terminal, and Ask is stubbed
  # alongside, so nothing here reads real input.
  def offer(stats, answer:, tty: true)
    filed = nil
    with_stdin("", tty: tty) do
      stub_singleton(Ask, :for_string, ->(_msg, _opts = {}) { answer }) do
        stub_global(:require_playbook_session!, ->(_local) { nil }) do
          stub_global(:issue_endpoint, ->(_local) { "endpoint" }) do
            stub_global(:issue_file_and_start, lambda { |**kwargs|
              filed = kwargs[:form]
              { "number" => "041" }
            }) do
              queries_offer_investigation(stats, hours: 168, sort: "total_ms", use_localhost: false)
            end
          end
        end
      end
    end
    filed
  end

  # Piping the ranking must print and exit. A prompt here would block on input
  # nobody can supply.
  def test_files_nothing_when_stdin_is_not_a_tty
    assert_nil offer([stat], answer: "all", tty: false)
  end

  def test_files_nothing_on_an_empty_answer
    assert_nil offer([stat], answer: "none")
  end

  def test_files_nothing_on_an_unparseable_answer
    filed = nil
    out = capture_stdout { filed = offer([stat], answer: "banana") }
    assert_nil filed
    assert_includes out, "Invalid selection"
  end

  # Three queries offered, two picked: one issue, holding exactly those two.
  def test_files_one_improvement_issue_for_the_whole_selection
    picked_sql = "select 1 from public.tasks where id = ?"
    passed_over_sql = "select id from court_reserve.reservations where club_id = ?"
    stats = [stat, stat(call_site: nil, sql: picked_sql), stat(sql: passed_over_sql)]

    filed = nil
    capture_stdout { filed = offer(stats, answer: "1,2") }

    refute_nil filed, "expected an issue to be filed"
    assert_equal "improvement", filed[:category]
    assert_includes filed[:body], "2 queries selected"
    assert_includes filed[:body], picked_sql
    refute_includes filed[:body], passed_over_sql
  end

  # One query is named by its call site; several are counted, because no single
  # title describes them.
  def test_title_names_the_call_site_for_a_single_query
    assert_equal "Expensive query: BaseMemberEngagementScoresDao.findAll", queries_issue_title([stat])
  end

  def test_title_falls_back_to_the_statement_when_there_is_no_call_site
    title = queries_issue_title([stat(call_site: nil, sql: "select 1 from public.tasks where id = ? for update")])
    assert_equal "Expensive query: select 1 from public.tasks where id = ? for update", title
  end

  def test_title_counts_a_multi_query_selection
    assert_equal "Expensive queries: 2 from the query-stats ranking", queries_issue_title([stat, stat])
  end

  # rules/llm.ticket.prompts.mdc: the receiving session has no context, so the
  # orientation is baked in rather than left to be re-derived.
  def test_body_names_the_code_paths_and_the_investigation
    body = queries_issue_body([stat], hours: 168, sort: "total_ms")
    %w[
      ~/code/platform/generated/app/util/QueryStats.scala
      ~/code/platform/generated/app/util/TimingConnection.scala
      ~/code/platform/core/app/core/actors/QueryStatsActor.scala
      ~/code/platform/dao/spec/
    ].each { |path| assert_includes body, path }
    assert_includes body, "EXPLAIN (ANALYZE, BUFFERS)"
    assert_includes body, "claude-db start"
    assert_includes body, "api --group dao"
  end

  # The three readings that are wrong by default. A session missing the first one
  # optimizes an insert that is really a whole transaction.
  def test_body_decodes_how_the_measurement_lies
    body = queries_issue_body([stat], hours: 168, sort: "total_ms")
    assert_includes body, "FIRST statement prepared in its block"
    assert_includes body, "collapsed to a single `?`"
    assert_includes body, "sums across nodes and windows"
    assert_includes body, "the application caller, not the DAO"
  end

  def test_body_carries_the_stats_and_the_untruncated_statement
    long = "select #{(1..200).map { |i| "column_#{i}" }.join(', ')} from playbook.members"
    body = queries_issue_body([stat(sql: long)], hours: 168, sort: "total_ms")
    assert_includes body, long
    assert_includes body, "67757 ms across 1348 calls"
    assert_includes body, "ranked by total_ms, last 7 day(s)"
  end

  def test_body_says_when_a_query_was_never_attributed
    body = queries_issue_body([stat(call_site: nil)], hours: 24, sort: "calls")
    assert_includes body, QUERIES_NO_CALL_SITE
  end

  # ISS-110 was filed against a select whose 107ms mean was a 500-row batch upsert running behind
  # it. The share is stated per query, and stated as a sentence, because a bare percentage is what
  # a session skims past.
  def test_body_says_when_the_duration_covers_sibling_statements
    body = queries_issue_body([stat(calls: 2067, multi_statement_calls: 2067)], hours: 168, sort: "total_ms")
    assert_includes body, "2067 of 2067 calls (100%)"
    assert_includes body, "cover sibling statements too"
  end

  def test_body_says_when_the_duration_is_the_statements_alone
    body = queries_issue_body([stat(calls: 1348, multi_statement_calls: 0)], hours: 168, sort: "total_ms")
    assert_includes body, "0 of 1348 calls — the duration below is this statement's alone"
  end

  def test_multi_share_is_quiet_for_the_ordinary_single_statement_case
    assert_equal "-", queries_multi_share(stat(multi_statement_calls: 0))
  end

  def test_multi_share_is_a_percentage_of_calls
    assert_equal "50%", queries_multi_share(stat(calls: 1348, multi_statement_calls: 674))
  end

  # The distinction ISS-850 could not make and ISS-854 exists to restore: a total says
  # nothing about whether the calls were one job or every request, and those are different
  # bugs. Spelled out for the same reason as the multi-statement share -- the receiving
  # session has no other context, and a bare "3 samples" means nothing to it.
  def test_body_says_whether_the_calls_were_a_burst_or_sustained
    body = queries_issue_body([stat], hours: 168, sort: "total_ms")
    assert_includes body, "2026-08-05 00:00 UTC to 2026-08-06 12:00 UTC"
    assert_includes body, "at least 1d12h of wall clock"
    assert_includes body, "dev queries show qs-1f0e"
  end

  def test_body_calls_a_single_window_a_burst_outright
    body = queries_issue_body([stat(sample_count: 1)], hours: 168, sort: "total_ms")
    assert_includes body, "ONE 6-hour flush window on ONE node"
    assert_includes body, "That is a burst, not a hot path"
  end

  # Several nodes flushing the same window is more than one sample and still a burst.
  def test_body_treats_a_zero_span_as_a_burst_however_many_samples
    body = queries_issue_body(
      [stat(sample_count: 4, first_sample_at: "2026-08-06T12:00:00.000Z", last_sample_at: "2026-08-06T12:00:00.000Z")],
      hours: 168, sort: "total_ms",
    )
    assert_includes body, "That is a burst, not a hot path"
  end

  # The next session has to be able to measure this rather than argue it from the flush
  # interval, which is what ISS-850 was reduced to.
  def test_body_points_at_the_command_that_measures_the_shape
    body = queries_issue_body([stat], hours: 168, sort: "total_ms")
    assert_includes body, "dev queries show <sample-id>"
    assert_includes body, "--hours N"
  end
end

# Covers the window the ranking is taken over, and the sample span it now reports.
#
# The window used to be whole days only, which is the bug: samples are flushed every 6
# hours, so days=1 and days=7 were the two adjacent readings available and neither can
# measure a spread of hours. ISS-850 could establish that 1048 of 1051 calls fell inside
# "roughly one day" and no more, so the invariant threshold it produced had to be argued
# from the flush interval rather than measured (ISS-854).
class TestDevQueriesWindow < Minitest::Test
  include DevTestSupport

  def hours(flag, value) = queries_window_hours(flag, value, "queries top")

  def test_hours_is_taken_verbatim
    assert_equal 6, hours("--hours", "6")
  end

  # Days is kept, as a multiple of the same unit: it is how the window is asked for most
  # of the time, and every existing playbook and issue body words it that way.
  def test_days_is_the_same_window_in_multiples_of_24
    assert_equal 168, hours("--days", "7")
  end

  def test_a_missing_value_is_a_usage_error
    _, status = capture_stderr_and_exit { hours("--hours", nil) }
    assert_equal 1, status
  end

  def test_a_window_below_one_is_a_usage_error
    _, status = capture_stderr_and_exit { hours("--hours", "0") }
    assert_equal 1, status
  end

  # Hours is what the window IS, but "last 168 hour(s)" is nobody's mental model of a week.
  def test_a_whole_number_of_days_reads_as_days
    assert_equal "7 day(s)", queries_window_label(168)
    assert_equal "1 day(s)", queries_window_label(24)
  end

  def test_a_finer_window_reads_as_hours
    assert_equal "12 hour(s)", queries_window_label(12)
    assert_equal "30 hour(s)", queries_window_label(30)
  end
end

# Covers the line under each ranked row: how many samples the row aggregates, what they
# span, and the command that opens them. This is the burst-vs-sustained answer the ranking
# alone cannot give, and it is the whole point of ISS-854.
class TestDevQueriesSpan < Minitest::Test
  include DevTestSupport

  def stat(id: "qs-abc", sample_count: 3,
           first_sample_at: "2026-08-06T00:00:00.000Z", last_sample_at: "2026-08-06T18:00:00.000Z")
    { "id" => id, "sample_count" => sample_count,
      "first_sample_at" => first_sample_at, "last_sample_at" => last_sample_at }
  end

  def line(**overrides)
    queries_span_line(stat(**overrides), hours: QUERIES_DEFAULT_HOURS, use_localhost: false)
  end

  # "at least", because a sample's window ENDS at its timestamp and covers the six hours
  # before it — so the true span reaches one window further back than the first sample.
  # Stating the bound as a bound is the difference between a measurement and a guess.
  def test_reports_the_span_as_a_lower_bound
    assert_includes line, "3 samples spanning at least 18h00m"
    assert_includes line, "2026-08-06 00:00 UTC -> 2026-08-06 18:00 UTC"
  end

  # One sample is the unambiguous burst: every call landed in one flush window on one node.
  def test_a_single_sample_is_a_point_in_time_not_a_span
    rendered = line(sample_count: 1, first_sample_at: "2026-08-06T18:00:00.000Z")
    assert_includes rendered, "1 sample at 2026-08-06 18:00 UTC"
    refute_includes rendered, "spanning"
  end

  # Several nodes flushing the same window is a span of zero over more than one sample —
  # still a burst, and it must not render as a span.
  def test_samples_sharing_one_window_are_not_a_span
    rendered = line(sample_count: 4, first_sample_at: "2026-08-06T18:00:00.000Z")
    assert_includes rendered, "4 samples at 2026-08-06 18:00 UTC"
    refute_includes rendered, "spanning"
  end

  def test_offers_the_command_that_opens_the_samples
    assert_includes line, "dev queries show qs-abc"
  end

  # The hint has to reproduce the ranking's own window and target, or it silently answers a
  # different question than the row it sits under.
  def test_the_command_carries_a_non_default_window_and_localhost
    rendered = queries_span_line(stat, hours: 12, use_localhost: true)
    assert_includes rendered, "dev queries show qs-abc --hours 12 --localhost"
  end

  def test_the_command_is_bare_at_the_default_window
    refute_includes line, "--hours"
    refute_includes line, "--localhost"
  end

  # Timestamps here are compared against deploy times and log windows from other machines.
  # Local time is the rendering that quietly loses an hour.
  def test_timestamps_are_rendered_in_utc
    assert_equal "2026-08-06 18:00 UTC", queries_format_time("2026-08-06T18:00:00.000Z")
  end

  def test_an_unparseable_timestamp_does_not_blow_up_the_row
    assert_equal "(unknown)", queries_format_time("not a time")
    assert_nil queries_parse_time(nil)
  end
end

# Covers `dev queries show`: the raw samples behind one statement, which is the half of the
# instrument that did not exist. `top` sums across every node and window — the right
# ranking, and it destroys the only fact a triage turns on.
class TestDevQueriesShow < Minitest::Test
  include DevTestSupport

  ID = "qs-abc".freeze

  def sample(id: "qs-1", created_at: "2026-08-06T00:00:00.000Z", node: "pod-a",
             calls: 100, total_ms: 5000, max_ms: 300, multi_statement_calls: 0, window_seconds: 21600)
    { "id" => id, "created_at" => created_at, "node" => node, "window_seconds" => window_seconds,
      "calls" => calls, "total_ms" => total_ms, "max_ms" => max_ms,
      "multi_statement_calls" => multi_statement_calls }
  end

  def history(samples:, sql: "select id from playbook.members where club_id = ?", call_site: "SomeDao.findAll")
    { "sql" => sql, "call_site" => call_site, "samples" => samples }
  end

  def show(args, response)
    out = nil
    stub_global(:platform_endpoint, ->(_local) { { name: "platform", app: "platform" } }) do
      with_stubbed_api("GET /dev/query/stats/#{ID}?hours=168" => response) do
        out = capture_stdout { cmd_queries_show(args) }
      end
    end
    out
  end

  def test_renders_a_row_per_sample_with_its_node_and_window
    out = show([ID], history(samples: [
      sample(created_at: "2026-08-06T00:00:00.000Z", node: "pod-a", calls: 100, total_ms: 5000),
      sample(created_at: "2026-08-06T06:00:00.000Z", node: "pod-b", calls: 20, total_ms: 400),
    ]))
    assert_includes out, "2026-08-06 00:00 UTC"
    assert_includes out, "2026-08-06 06:00 UTC"
    assert_includes out, "pod-a"
    assert_includes out, "pod-b"
    assert_includes out, "6h00m" # the window each row covers
    assert_includes out, "SomeDao.findAll"
  end

  # The summary is the reading: an hours-long span across one node is a batch job, and the
  # same call count spread over days across the fleet is a hot path.
  def test_summarizes_the_span_across_nodes
    out = show([ID], history(samples: [
      sample(created_at: "2026-08-06T00:00:00.000Z", node: "pod-a", calls: 1000, total_ms: 90000),
      sample(created_at: "2026-08-06T06:00:00.000Z", node: "pod-a", calls: 51, total_ms: 4000),
    ]))
    assert_includes out, "2 samples across 1 node spanning at least 6h00m: 1051 calls, 94000 ms."
  end

  def test_a_single_sample_reports_no_span
    out = show([ID], history(samples: [sample(calls: 7, total_ms: 70)]))
    assert_includes out, "1 sample across 1 node: 7 calls, 70 ms."
    refute_includes out, "spanning"
  end

  # A known statement that has been quiet is a finding, and a different one from an id that
  # names nothing — so it prints as an empty window rather than as an error.
  def test_an_empty_window_says_so_rather_than_failing
    out = show([ID], history(samples: []))
    assert_includes out, "has not run recently"
  end

  # The raw "HTTP 404" says the request failed; what happened is that this id names nothing,
  # and the id came from a ranking or an invariant, so the next question is which.
  def test_an_unknown_id_is_reworded_and_exits_nonzero
    err, status = capture_stderr_and_exit do
      stub_global(:platform_endpoint, ->(_local) { { name: "platform", app: "platform" } }) do
        with_stubbed_api("GET /dev/query/stats/#{ID}?hours=168" => ->(_body) { raise ApiError.new("HTTP 404", code: 404) }) do
          capture_stdout { cmd_queries_show([ID]) }
        end
      end
    end
    assert_equal 1, status
    assert_includes err, "No sample `#{ID}`"
    assert_includes err, "dev queries top"
  end

  def test_requires_a_sample_id
    _, status = capture_stderr_and_exit { cmd_queries_show([]) }
    assert_equal 1, status
  end

  def test_rejects_a_second_positional_argument
    _, status = capture_stderr_and_exit { cmd_queries_show(%w[qs-a qs-b]) }
    assert_equal 1, status
  end

  def test_rejects_an_unknown_flag
    _, status = capture_stderr_and_exit { cmd_queries_show([ID, "--bogus"]) }
    assert_equal 1, status
  end
end
