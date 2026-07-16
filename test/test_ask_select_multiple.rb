#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
load File.expand_path('../lib/ask.rb', __dir__)

# The prompt loop around parse_selection: it must keep asking until an answer
# parses, and must not treat a rejected answer as "select nothing".
class TestAskSelectMultipleFromList < Minitest::Test
  VALUES = %w[acumen rallyd hackathon].freeze

  # Feeds scripted answers in place of stdin, and records the prompts shown.
  def with_answers(answers)
    @prompts = []
    prompts_ref = @prompts
    remaining = answers.dup
    Ask.singleton_class.send(:alias_method, :orig_for_string, :for_string)
    Ask.define_singleton_method(:for_string) do |msg, opts = {}|
      prompts_ref << msg
      raise "prompt loop asked more than #{answers.length} times" if remaining.empty?
      raw = remaining.shift
      # Mirror for_string's own empty-input-takes-the-default behavior.
      raw.to_s.strip.empty? && opts[:default] ? opts[:default].to_s : raw
    end
    yield
  ensure
    Ask.singleton_class.send(:alias_method, :for_string, :orig_for_string)
  end

  def capture_io
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def test_reprompts_until_valid_then_returns_selection
    result = nil
    out = with_answers(["9", "bogus", "2"]) do
      capture_io { result = Ask.select_multiple_from_list("Deploy which?", VALUES) }
    end
    assert_equal %w[rallyd], result
    assert_equal 3, @prompts.length, "must re-ask once per rejected answer"
    assert_match(/Invalid selection/, out)
  end

  def test_empty_input_takes_the_all_default
    result = nil
    with_answers([""]) { capture_io { result = Ask.select_multiple_from_list("Deploy which?", VALUES) } }
    assert_equal VALUES, result
  end

  def test_prompt_lists_values_and_marks_the_default
    with_answers(["none"]) { capture_io { Ask.select_multiple_from_list("Deploy which?", VALUES) } }
    prompt = @prompts.first
    assert_match(/Deploy which\?/, prompt)
    assert_match(/  1\. acumen/, prompt)
    assert_match(/  3\. hackathon/, prompt)
    assert_match(/\[all\]:/, prompt, "default must be shown inline so for_string doesn't append its own")
  end

  def test_explicit_default_is_honored
    result = nil
    with_answers([""]) do
      capture_io { result = Ask.select_multiple_from_list("Deploy which?", VALUES, default: "none") }
    end
    assert_empty result
  end
end

# Ask.parse_selection is the pure core of Ask.select_multiple_from_list: it maps
# one raw answer to the chosen subset, or nil when the prompt must re-ask.
class TestAskParseSelection < Minitest::Test
  VALUES = %w[acumen rallyd hackathon].freeze

  def parse(raw)
    Ask.parse_selection(raw, VALUES)
  end

  def test_all_returns_everything
    Ask::ALL.each { |v| assert_equal VALUES, parse(v), "#{v.inspect} should select all" }
    assert_equal VALUES, parse("ALL"), "matching is case-insensitive"
  end

  def test_all_returns_a_copy_not_the_original_list
    result = parse("all")
    result << "mutated"
    assert_equal %w[acumen rallyd hackathon], VALUES, "caller must not be able to mutate the source list"
  end

  def test_none_returns_empty
    Ask::NONE.each { |v| assert_empty parse(v), "#{v.inspect} should select nothing" }
  end

  def test_single_index
    assert_equal %w[acumen], parse("1")
  end

  def test_comma_and_space_separated_indexes
    assert_equal %w[acumen hackathon], parse("1,3")
    assert_equal %w[acumen hackathon], parse("1 3")
    assert_equal %w[acumen hackathon], parse("1, 3")
  end

  def test_indexes_are_deduped_and_ordered_by_list_position
    assert_equal %w[acumen rallyd], parse("2,1,2")
  end

  def test_surrounding_whitespace_ignored
    assert_equal %w[rallyd], parse("  2  ")
  end

  def test_out_of_range_is_invalid
    assert_nil parse("0"), "indexes are 1-based"
    assert_nil parse("4")
    assert_nil parse("1,9"), "one bad index invalidates the whole answer"
  end

  def test_non_numeric_is_invalid
    ["x", "1,x", "acumen", "-1", "1.5"].each do |raw|
      assert_nil parse(raw), "#{raw.inspect} should be rejected"
    end
  end

  # Empty input never reaches parse_selection (Ask.for_string substitutes the
  # default first), but it must not be mistaken for "select nothing".
  def test_empty_is_invalid
    assert_nil parse("")
    assert_nil parse("   ")
  end
end
