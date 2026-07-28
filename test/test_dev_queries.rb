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
           total_ms: 67757, calls: 1348, mean_ms: 50, max_ms: 255)
    { "sql" => sql, "call_site" => call_site, "total_ms" => total_ms,
      "calls" => calls, "mean_ms" => mean_ms, "max_ms" => max_ms }
  end

  # Drive the prompt with a canned answer and a stubbed tty, and record whether
  # anything was filed. Returns the form passed to the filing helper, or nil.
  # Stands in for $stdin: the offer asks it whether it is a terminal, and Ask is
  # stubbed alongside, so nothing here reads real input.
  FakeStdin = Struct.new(:is_tty) do
    def tty? = is_tty
  end

  def offer(stats, answer:, tty: true)
    filed = nil
    with_stdin(FakeStdin.new(tty)) do
      stub_singleton(Ask, :for_string, ->(_msg, _opts = {}) { answer }) do
        stub_global(:require_playbook_session!, ->(_local) { nil }) do
          stub_global(:issue_endpoint, ->(_local) { "endpoint" }) do
            stub_global(:issue_file_claim_and_start, lambda { |**kwargs|
              filed = kwargs[:form]
              { "number" => "041" }
            }) do
              queries_offer_investigation(stats, days: 7, sort: "total_ms", use_localhost: false)
            end
          end
        end
      end
    end
    filed
  end

  def with_stdin(io)
    original = $stdin
    $stdin = io
    yield
  ensure
    $stdin = original
  end

  def stub_singleton(obj, name, impl)
    original = obj.method(name)
    obj.define_singleton_method(name, &impl)
    yield
  ensure
    obj.define_singleton_method(name, original)
  end

  def stub_global(name, impl)
    original = method(name)
    Object.send(:define_method, name, &impl)
    yield
  ensure
    Object.send(:define_method, name, original)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
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
    body = queries_issue_body([stat], days: 7, sort: "total_ms")
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
    body = queries_issue_body([stat], days: 7, sort: "total_ms")
    assert_includes body, "FIRST statement prepared in its block"
    assert_includes body, "collapsed to a single `?`"
    assert_includes body, "sums across nodes and windows"
  end

  def test_body_carries_the_stats_and_the_untruncated_statement
    long = "select #{(1..200).map { |i| "column_#{i}" }.join(', ')} from playbook.members"
    body = queries_issue_body([stat(sql: long)], days: 7, sort: "total_ms")
    assert_includes body, long
    assert_includes body, "67757 ms across 1348 calls"
    assert_includes body, "ranked by total_ms, last 7 day(s)"
  end

  def test_body_says_when_a_query_was_never_attributed
    body = queries_issue_body([stat(call_site: nil)], days: 1, sort: "calls")
    assert_includes body, "never got hot"
  end
end
