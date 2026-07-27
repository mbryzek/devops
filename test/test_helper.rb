require 'minitest/autorun'
require 'stringio'

# Shared across dev CLI tests: run a block that is expected to call `exit`,
# capturing whatever it wrote to stderr. Returns [stderr_string, exit_status]
# (status is nil if the block never exits). Include DevTestSupport in the test
# class to use it as an instance method.
module DevTestSupport
  # Raised when a test reaches the network instead of stubbing it. Loud and typed
  # so a test that WANTS to prove a command cannot escape can assert on it.
  class NetworkBlocked < StandardError; end

  # The test process is credential-bearing by construction: this box holds a
  # human session, and inside a Claude session `dev` presents the AI's API token
  # (ApiClient.auth_header_for). So a test that calls a `cmd_*` function is one
  # missing guard away from writing to PRODUCTION - which is exactly what
  # happened: the issues arg-validation tests snoozed and re-fixed the real
  # ISS-034 dozens of times.
  #
  # The fix is to make the network unreachable by default rather than to stub
  # credentials test by test: every credential accessor reads as "not logged in"
  # and every request raises. A test that legitimately exercises a request opts
  # back in with `with_stubbed_api` (or its own stub), which overrides these.
  module NetworkGuard
    ACCESSORS = %i[auth_header_for session_id_for ai_token].freeze

    def self.install
      return unless defined?(ApiClient)
      @saved = { request: ApiClient.method(:request) }
      ApiClient.define_singleton_method(:request) do |_endpoint, method, path, **_opts|
        raise DevTestSupport::NetworkBlocked,
              "test attempted a live API request: #{method.to_s.upcase} #{path} - " \
              "stub it with with_stubbed_api instead of letting it reach the network"
      end
      ACCESSORS.each do |name|
        next unless ApiClient.respond_to?(name)
        @saved[name] = ApiClient.method(name)
        ApiClient.define_singleton_method(name) { |*_args, **_kwargs| nil }
      end
    end

    def self.uninstall
      return unless defined?(ApiClient) && @saved
      @saved.each { |name, original| ApiClient.define_singleton_method(name, original) }
      @saved = nil
    end
  end

  # Wraps every test in every class that loads this helper. `before_setup` /
  # `after_teardown` rather than `setup` / `teardown` so a test class defining
  # its own setup cannot silently drop the guard.
  module GuardEveryTest
    def before_setup
      super
      DevTestSupport::NetworkGuard.install
    end

    def after_teardown
      DevTestSupport::NetworkGuard.uninstall
      super
    end
  end

  # Run a block on a box that IS logged in — the normal state of every machine and
  # every Claude session. Use it to prove that a credential is not, on its own,
  # enough to let a test reach production.
  def with_credentials
    orig = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:session_id_for) { |app, use_localhost:| "sess-#{app}" }
    yield
  ensure
    ApiClient.define_singleton_method(:session_id_for, orig)
  end

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
  # the network. Credentials are stubbed present here - NetworkGuard reads them as
  # absent, which would stop a command at its credential guard before it ever got
  # to the request under test.
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

Minitest::Test.prepend(DevTestSupport::GuardEveryTest)
