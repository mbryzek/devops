#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
load File.expand_path('../lib/ask.rb', __dir__)

# Ask.for_string must not crash or spin when stdin has no answer to give — EOF /
# closed stdin, which is what non-interactive callers see: a pipe, cron, or
# Open3.capture* (it closes the child's stdin). Regression for the `dev deploy`
# crash where release-sveltekit reached a wrangler-login prompt under a closed
# stdin and died on `nil.strip!`, burying the real "run wrangler login" message.
class TestAskForString < Minitest::Test
  def with_stdin(io)
    old = $stdin
    $stdin = io
    yield
  ensure
    $stdin = old
  end

  # for_string writes the prompt to stdout; keep the test output clean.
  def silently
    old = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old
  end

  def test_eof_with_default_returns_default
    result = nil
    with_stdin(StringIO.new("")) do
      silently { result = Ask.for_string("Name?", default: "abc") }
    end
    assert_equal "abc", result
  end

  def test_eof_without_default_raises_naming_the_prompt
    with_stdin(StringIO.new("")) do
      err = assert_raises(RuntimeError) do
        silently { Ask.for_string("Run `wrangler login` now?") }
      end
      assert_match(/stdin is not interactive/, err.message)
      assert_match(/wrangler login/, err.message, "the failing prompt must be named so the error is actionable")
    end
  end

  # for_boolean has no default, so an EOF must surface as the clear raise rather
  # than looping forever on nil.
  def test_for_boolean_at_eof_raises
    with_stdin(StringIO.new("")) do
      assert_raises(RuntimeError) { silently { Ask.for_boolean("Proceed?") } }
    end
  end

  def test_reads_a_normal_line
    result = nil
    with_stdin(StringIO.new("hello\n")) do
      silently { result = Ask.for_string("Name?") }
    end
    assert_equal "hello", result
  end

  def test_blank_line_takes_the_default
    result = nil
    with_stdin(StringIO.new("\n")) do
      silently { result = Ask.for_string("Name?", default: "def") }
    end
    assert_equal "def", result
  end
end
