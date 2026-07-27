require 'stringio'

# Shared across dev CLI tests: run a block that is expected to call `exit`,
# capturing whatever it wrote to stderr. Returns [stderr_string, exit_status]
# (status is nil if the block never exits). Include DevTestSupport in the test
# class to use it as an instance method.
module DevTestSupport
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

  # Run a block with every ApiClient request answered from `responses`, keyed by
  # "GET /path". A request with no stubbed key fails the test rather than hitting
  # the network. Credentials are stubbed too: the box running the tests may or may
  # not hold a real session, and a command that got past the guard would fire a
  # live request at production.
  def with_stubbed_api(responses)
    test = self
    orig_request = ApiClient.method(:request)
    orig_sid = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:request) do |_endpoint, method, path, **_opts|
      key = "#{method.to_s.upcase} #{path}"
      test.flunk("unstubbed request: #{key}") unless responses.key?(key)
      responses.fetch(key)
    end
    ApiClient.define_singleton_method(:session_id_for) { |app, use_localhost:| "sess-#{app}" }
    yield
  ensure
    ApiClient.define_singleton_method(:request, orig_request)
    ApiClient.define_singleton_method(:session_id_for, orig_sid)
  end
end
