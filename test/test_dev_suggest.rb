#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
load File.expand_path('../bin/dev', __dir__)

# Covers the command-suggestion + trimmed-error behavior added to `dev`:
# levenshtein distance, the suggest() prefix/edit-distance heuristic, and the
# usage_exit()/unknown() output (short error on mistake, full usage on help).
class TestDevSuggest < Minitest::Test
  # ---- levenshtein ----

  def test_levenshtein_identical_is_zero
    assert_equal 0, levenshtein("tasks", "tasks")
  end

  def test_levenshtein_empty_inputs
    assert_equal 3, levenshtein("", "abc")
    assert_equal 3, levenshtein("abc", "")
    assert_equal 0, levenshtein("", "")
  end

  def test_levenshtein_classic_vectors
    assert_equal 3, levenshtein("kitten", "sitting")
    assert_equal 3, levenshtein("saturday", "sunday")
    assert_equal 1, levenshtein("task", "tasks")
    assert_equal 1, levenshtein("requeu", "requeue")
  end

  # ---- suggest ----

  def test_suggest_single_char_typo
    assert_equal "tasks", suggest("task", COMMANDS)
    assert_equal "requeue", suggest("requeu", SUBCOMMANDS["tasks"])
    assert_equal "release", suggest("relese", SUBCOMMANDS["pending"])
  end

  def test_suggest_unique_prefix
    assert_equal "invariants", suggest("inv", COMMANDS)
    assert_equal "browserslist", suggest("browser", COMMANDS)
  end

  def test_suggest_ambiguous_prefix_does_not_guess
    # "lo" prefixes both login and logout — too far in edit distance for either,
    # so no suggestion rather than an arbitrary one.
    assert_nil suggest("lo", COMMANDS)
  end

  def test_suggest_no_match_for_unrelated_input
    assert_nil suggest("zzzz", COMMANDS)
    assert_nil suggest("xylophone", COMMANDS)
  end

  def test_suggest_empty_input
    assert_nil suggest("", COMMANDS)
    assert_nil suggest(nil, COMMANDS)
  end

  def test_suggest_is_case_insensitive
    assert_equal "tasks", suggest("TASK", COMMANDS)
  end

  def test_suggest_does_not_return_input_itself
    # An exact match is a real command, never an "unknown" — suggest must not
    # echo it back. (Single-letter prefix guard also blocks it.)
    assert_nil suggest("t", SUBCOMMANDS["tasks"])
  end

  # ---- unknown / usage_exit output ----

  def capture_stderr_and_exit
    buf = StringIO.new
    old = $stderr
    $stderr = buf
    status = nil
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [buf.string, status]
  ensure
    $stderr = old
  end

  def test_unknown_with_suggestion_is_short
    out, status = capture_stderr_and_exit { unknown("command", "task", COMMANDS) }
    assert_equal 1, status
    assert_match(/Unknown command: task \(did you mean 'tasks'\?\)/, out)
    assert_match(/Run `dev help` for usage\./, out)
    refute_match(/Usage: dev <command>/, out) # NOT the full block
  end

  def test_unknown_without_suggestion_omits_hint
    out, status = capture_stderr_and_exit { unknown("command", "zzzz", COMMANDS) }
    assert_equal 1, status
    assert_match(/Unknown command: zzzz/, out)
    refute_match(/did you mean/, out)
    refute_match(/Usage: dev <command>/, out)
  end

  def test_usage_exit_error_is_short_and_nonzero
    out, status = capture_stderr_and_exit { usage_exit("--app requires a value") }
    assert_equal 1, status
    assert_match(/--app requires a value/, out)
    assert_match(/Run `dev help` for usage\./, out)
    refute_match(/Usage: dev <command>/, out)
  end

  def test_usage_exit_help_prints_full_usage_and_exits_zero
    out, status = capture_stderr_and_exit { usage_exit }
    assert_equal 0, status
    assert_match(/Usage: dev <command>/, out)
  end
end
