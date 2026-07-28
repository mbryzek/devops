#!/usr/bin/env ruby
require_relative 'test_helper'
require_relative '../lib/common'

# A `api` run died with "SSL_read: unexpected eof while reading" while reading
# the response to POST /apibuilder/batches - a request the server had already
# answered 201. These cover the transport layer that now absorbs that.
class TestApibuilderClientRetry < Minitest::Test
  include DevTestSupport

  Response = Struct.new(:code, :body)

  # Answers each request from a script of responses/exceptions, in order.
  class ScriptedHttp
    attr_reader :calls

    def initialize(script)
      @script = script
      @calls = 0
    end

    def request(_req)
      outcome = @script.fetch(@calls, nil)
      @calls += 1
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
  end

  class TestClient < ApibuilderClient
    attr_reader :http, :slept

    def initialize(script)
      @base_uri = "https://example.test"
      @token = "test-token"
      @http = ScriptedHttp.new(script)
      @slept = []
    end

    private

    def build_http(_uri)
      @http
    end

    def sleep_for(seconds)
      @slept << seconds
    end
  end

  def ssl_eof
    OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading")
  end

  def test_retries_dropped_connection_and_returns_the_eventual_response
    client = TestClient.new([ssl_eof, Response.new("201", '{"id":"bat-1"}')])

    out, _ = capture_stderr_and_exit do
      response = client.raw_request(:post, "/apibuilder/batches", { "applications" => [] })
      assert_equal "201", response.code
    end

    assert_equal 2, client.http.calls
    assert_equal [1], client.slept
    assert_match(/POST \/apibuilder\/batches failed/, out)
    assert_match(/attempt 2 of 3/, out)
  end

  def test_retries_gateway_status_from_a_rolling_backend
    client = TestClient.new([Response.new("503", ""), Response.new("200", "{}")])

    capture_stderr_and_exit do
      assert_equal "200", client.raw_request(:get, "/apibuilder/batches/bat-1").code
    end

    assert_equal 2, client.http.calls
    assert_equal [1], client.slept
  end

  def test_gives_up_after_max_attempts_with_an_actionable_error
    client = TestClient.new([ssl_eof, ssl_eof, ssl_eof])

    out, status = capture_stderr_and_exit do
      client.raw_request(:post, "/apibuilder/batches", { "applications" => [] })
    end

    assert_equal 1, status
    assert_equal 3, client.http.calls
    assert_equal [1, 3], client.slept
    assert_match(/failed after 3 attempts/, out)
    assert_match(/may still have accepted it/, out)
  end

  def test_connection_refused_still_reports_a_down_server
    client = TestClient.new(Array.new(3) { Errno::ECONNREFUSED.new })

    out, status = capture_stderr_and_exit do
      client.raw_request(:get, "/apibuilder/batches/bat-1")
    end

    assert_equal 1, status
    assert_match(/Cannot connect to https:\/\/example\.test/, out)
    assert_match(/Is the server running\?/, out)
  end

  def test_application_errors_are_returned_untouched_not_retried
    client = TestClient.new([Response.new("422", '[{"message":"invalid"}]')])

    capture_stderr_and_exit do
      assert_equal "422", client.raw_request(:post, "/apibuilder/batches", {}).code
    end

    assert_equal 1, client.http.calls
    assert_empty client.slept
  end

  def test_download_retries_and_returns_the_body
    client = TestClient.new([ssl_eof, Response.new("200", "zip-bytes")])

    capture_stderr_and_exit do
      assert_equal "zip-bytes", client.download("https://example.test/batch.zip")
    end

    assert_equal 2, client.http.calls
  end
end
