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
