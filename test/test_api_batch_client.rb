#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require_relative '../lib/common'
require_relative 'test_helper'

# Waiting on an apibuilder batch.
#
# The behaviour under test is what happens when the batch does NOT finish
# quickly. That path used to poll for ~30 seconds and then ask "Still
# processing. Cancel or keep waiting? [c/w]" on stdin — which is fine at a
# keyboard and catastrophic everywhere else, because every caller that matters
# is a release: `bin/release` runs `api publish` through `Util.run` in quiet
# mode, which sends the child's stdout and stderr to a log file. The question
# went into the log, the answer had to come from a terminal showing a live
# progress display, and `dev deploy` sat on "Publishing apibuilder specs..." for
# 23 minutes on 2026-08-07 before a human gave up and hit Ctrl-C.
#
# So: no prompt, a deadline, and a message that says what the server was last
# doing. The two tests that matter are that a slow batch ENDS, and that reaching
# stdin at all is impossible.
class TestApiBatchClient < Minitest::Test
  include DevTestSupport

  ORG = "bryzek".freeze
  ID = "bat-1234".freeze

  # Serves a canned sequence of batch responses; the last one repeats forever,
  # which is how "the server never finishes" is expressed.
  class FakeClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = 0
    end

    def request(method, path, form = nil)
      raise "unexpected #{method} #{path}" unless method == :get && path.end_with?(ID)
      @calls += 1
      @responses[[@calls - 1, @responses.size - 1].min]
    end
  end

  def processing(completed, total = 64)
    { "status" => "processing",
      "operations" => [{ "operation" => "codegen", "completed" => completed, "total" => total }] }
  end

  def done
    { "status" => "done",
      "operations" => [{ "operation" => "codegen", "completed" => 64, "total" => 64 }] }
  end

  # A clock that advances by `step` on every read, so a 900s deadline is reached
  # in a handful of polls rather than in fifteen real minutes. Sleeps are counted,
  # not taken.
  def client_for(responses, timeout_seconds: 900, step: 100)
    @slept = []
    now = 0.0
    ApiBatchClient.new(FakeClient.new(responses),
                       timeout_seconds: timeout_seconds,
                       clock: -> { now += step },
                       sleeper: ->(seconds) { @slept << seconds })
  end

  def silently
    out = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = out
  end

  def test_returns_the_batch_once_it_is_done
    batch_client = client_for([processing(10), processing(40), done])
    result = silently { batch_client.poll_until_complete(ORG, ID) }
    assert_equal "done", result["status"]
  end

  def test_an_error_status_is_terminal_and_returned_rather_than_raised
    errored = { "status" => "error", "errors" => [{ "message" => "boom" }] }
    batch_client = client_for([processing(10), errored])
    result = silently { batch_client.poll_until_complete(ORG, ID) }
    assert_equal "error", result["status"]
  end

  # The regression: a batch that never terminates has to END, not wait forever.
  def test_a_batch_that_never_finishes_raises_rather_than_waiting_forever
    batch_client = client_for([processing(34)])
    error = assert_raises(ApiBatchClient::Timeout) do
      silently { batch_client.poll_until_complete(ORG, ID) }
    end
    assert_includes error.message, ID
    assert_includes error.message, "codegen 34/64", "the last progress is the diagnosis"
    assert_includes error.message, "900s"
  end

  # The bug itself, stated directly: nothing on this path may read stdin. A
  # prompt printed into a redirected log is not a prompt, it is a hang.
  def test_waiting_never_reads_stdin
    reader = Object.new
    def reader.gets(*) = raise("poll_until_complete read stdin")
    def reader.read(*) = raise("poll_until_complete read stdin")

    saved = $stdin
    $stdin = reader
    begin
      batch_client = client_for([processing(0)])
      assert_raises(ApiBatchClient::Timeout) do
        silently { batch_client.poll_until_complete(ORG, ID) }
      end
    ensure
      $stdin = saved
    end
  end

  # Polling that does not sleep is a tight loop against the API.
  def test_polling_sleeps_between_requests
    batch_client = client_for([processing(10), processing(40), done])
    silently { batch_client.poll_until_complete(ORG, ID) }
    assert_equal [ApiBatchClient::FIRST_POLL_DELAY, ApiBatchClient::POLL_INTERVAL, ApiBatchClient::POLL_INTERVAL],
                 @slept
  end
end
