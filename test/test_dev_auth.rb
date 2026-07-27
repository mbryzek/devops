#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev auth`: the identity reporting, and the `auth ai provision`/`revoke`
# flows that mint and kill the AI actor's credential. Every HTTP call and every
# write to ~/.platform is stubbed - these tests must never touch production or
# the real token file.
class TestDevAuth < Minitest::Test
  include DevTestSupport

  def setup
    @requests = []
    @written = nil
    @cleared = false
  end

  # Stub the whole credential I/O surface. `responses` maps "METHOD /path" to the
  # parsed body to return (or an exception instance to raise). An unstubbed call
  # fails the test rather than escaping to the network.
  def with_api(responses, ai_session: false)
    orig_request = ApiClient.method(:request)
    orig_write   = ApiClient.method(:write_ai_token)
    orig_clear   = ApiClient.method(:clear_ai_token)
    orig_session = ApiClient.method(:ai_session?)
    requests = @requests
    test = self

    ApiClient.define_singleton_method(:request) do |endpoint, method, path, **opts|
      requests << { method: method, path: path, body: opts[:body], as_token: opts[:as_token] }
      key = "#{method.to_s.upcase} #{path}"
      test.flunk("unstubbed request: #{key}") unless responses.key?(key)
      value = responses.fetch(key)
      raise value if value.is_a?(StandardError)
      value
    end
    ApiClient.define_singleton_method(:write_ai_token) { |token, use_localhost:| test.instance_variable_set(:@written, token) }
    ApiClient.define_singleton_method(:clear_ai_token) { |use_localhost:| test.instance_variable_set(:@cleared, true) }
    ApiClient.define_singleton_method(:ai_session?) { ai_session }

    yield
  ensure
    ApiClient.define_singleton_method(:request, orig_request)
    ApiClient.define_singleton_method(:write_ai_token, orig_write)
    ApiClient.define_singleton_method(:clear_ai_token, orig_clear)
    ApiClient.define_singleton_method(:ai_session?, orig_session)
  end

  # Run a command that both prints and exits, returning [stdout, stderr, status].
  # Util.exit_with_error writes to $stderr, so stdout and stderr must be captured
  # by the SAME capture_io - nesting the two swallows one of them.
  def run_cmd
    status = nil
    out, err = capture_io do
      begin
        yield
      rescue SystemExit => e
        status = e.status
      end
    end
    [out, err, status]
  end

  def token_row(id: "tok-old", masked: "at****wxyz")
    { "id" => id, "masked_token" => masked, "description" => "dev CLI on laptop", "created_at" => "2026-07-01T00:00:00Z" }
  end

  def provision_responses(existing: [])
    {
      "GET /users/ai"           => { "id" => "ai" },
      "GET /tokens/users/ai"    => existing,
      "POST /tokens"            => { "id" => "tok-new", "masked_token" => "at****abcd" },
      "GET /tokens/tok-new/cleartext" => { "token" => "at-cleartext-value" },
    }
  end

  def paths_requested
    @requests.map { |r| "#{r[:method].to_s.upcase} #{r[:path]}" }
  end

  # ---- identity reporting ----

  def test_effective_identity_distinguishes_human_from_ai_session
    with_api({}, ai_session: false) do
      assert_match(/authenticates as you/, auth_effective_identity("at-token"))
    end
    with_api({}, ai_session: true) do
      assert_match(/authenticates as Otto AI/, auth_effective_identity("at-token"))
      assert_match(/falls back to your session/, auth_effective_identity(nil))
    end
  end

  def test_mask_token_never_reveals_the_middle
    assert_equal "atab...wxyz", mask_token("atabcdefghijwxyz")
    assert_equal "****", mask_token("short")
    assert_equal "****", mask_token(nil)
  end

  # ---- provision ----

  def test_provision_mints_stores_and_verifies
    with_api(provision_responses) do
      out, _, _ = run_cmd { cmd_auth_ai_provision([]) }
      assert_equal "at-cleartext-value", @written
      assert_match(/Minted at\*\*\*\*abcd/, out)
      assert_match(/Verified/, out)
    end
    assert_equal(
      ["GET /users/ai", "GET /tokens/users/ai", "POST /tokens", "GET /tokens/tok-new/cleartext", "GET /tokens/users/ai"],
      paths_requested
    )
    assert_equal "ai", @requests.find { |r| r[:method] == :post }[:body][:user_id]
  end

  # The verification call must present the NEW token, not whatever credential the
  # process would otherwise resolve - otherwise it proves nothing about the token
  # just written to disk.
  def test_provision_verifies_with_the_minted_token
    with_api(provision_responses) do
      run_cmd { cmd_auth_ai_provision([]) }
    end
    assert_equal "at-cleartext-value", @requests.last[:as_token]
  end

  def test_provision_refuses_when_tokens_already_exist
    with_api(provision_responses(existing: [token_row])) do
      _, out, status = run_cmd { cmd_auth_ai_provision([]) }
      assert_equal 1, status
      assert_match(/already has 1 live token/, out)
      assert_match(/--rotate/, out)
    end
    assert_nil @written, "must not mint a second token without --rotate"
    refute_includes paths_requested, "POST /tokens"
  end

  # Order matters: the new token is stored before the old ones are revoked, so a
  # failure mid-rotation leaves a working credential rather than none.
  def test_rotate_stores_before_revoking_old_tokens
    responses = provision_responses(existing: [token_row]).merge("DELETE /tokens/tok-old" => nil)
    with_api(responses) do
      out, _, _ = run_cmd { cmd_auth_ai_provision(["--rotate"]) }
      assert_match(/Revoked at\*\*\*\*wxyz/, out)
    end
    assert_equal "at-cleartext-value", @written
    assert_operator paths_requested.index("POST /tokens"), :<, paths_requested.index("DELETE /tokens/tok-old")
  end

  def test_provision_names_the_migration_when_the_ai_user_is_missing
    with_api(provision_responses.merge("GET /users/ai" => ApiError.new("HTTP 404 GET /users/ai"))) do
      _, out, status = run_cmd { cmd_auth_ai_provision([]) }
      assert_equal 1, status
      assert_match(/No `ai` user on prod/, out)
      assert_match(/platform-postgresql migration/, out)
    end
    assert_nil @written
  end

  def test_provision_fails_loudly_when_the_cleartext_was_already_claimed
    responses = provision_responses.merge("GET /tokens/tok-new/cleartext" => { "token" => "" })
    with_api(responses) do
      _, out, status = run_cmd { cmd_auth_ai_provision([]) }
      assert_equal 1, status
      assert_match(/cleartext was already claimed/, out)
    end
    assert_nil @written
  end

  def test_provision_fails_when_the_stored_token_does_not_authenticate
    with_api(provision_responses) do
      # Second read of the token list (the verification) rejects the credential.
      stubbed = ApiClient.method(:request)
      ApiClient.define_singleton_method(:request) do |endpoint, method, path, **opts|
        raise SessionExpired, "Invalid API token" if opts[:as_token]
        stubbed.call(endpoint, method, path, **opts)
      end
      _, out, status = run_cmd { cmd_auth_ai_provision([]) }
      assert_equal 1, status
      assert_match(/failed to authenticate/, out)
    end
  end

  # ---- the AI may not provision itself ----

  def test_provision_and_revoke_refuse_inside_a_claude_session
    with_api({}, ai_session: true) do
      [-> { cmd_auth_ai_provision([]) }, -> { cmd_auth_ai_revoke([]) }].each do |callable|
        _, out, status = run_cmd { callable.call }
        assert_equal 1, status
        assert_match(/Refusing to (provision|revoke) a token inside a Claude session/, out)
      end
    end
    assert_empty @requests, "no network call may be made from a Claude session"
  end

  # ---- revoke / clear ----

  def test_revoke_kills_every_live_token_and_clears_locally
    responses = { "GET /tokens/users/ai" => [token_row, token_row(id: "tok-2", masked: "at****2222")],
                  "DELETE /tokens/tok-old" => nil, "DELETE /tokens/tok-2" => nil }
    with_api(responses) do
      out, _, _ = run_cmd { cmd_auth_ai_revoke([]) }
      assert_match(/Revoked at\*\*\*\*wxyz/, out)
      assert_match(/Revoked at\*\*\*\*2222/, out)
    end
    assert @cleared, "the local copy must be forgotten too"
  end

  def test_revoke_with_no_tokens_still_clears_locally
    with_api({ "GET /tokens/users/ai" => [] }) do
      out, _, _ = run_cmd { cmd_auth_ai_revoke([]) }
      assert_match(/has no live tokens/, out)
    end
    assert @cleared
  end

  # `clear` is local-only: it must never call the server, or it would be
  # indistinguishable from `revoke`.
  def test_clear_is_local_only
    with_api({}) do
      out, _, _ = run_cmd { cmd_auth_ai_clear([]) }
      assert_match(/still valid server-side/, out)
    end
    assert @cleared
    assert_empty @requests
  end

  def test_set_stores_the_given_token
    with_api({}) do
      run_cmd { cmd_auth_ai_set(["at-pasted-token"]) }
    end
    assert_equal "at-pasted-token", @written
  end

  # ---- flag parsing ----

  def test_parse_auth_flags_reads_localhost_and_allowed_flags
    assert_equal [true, { rotate: true }], parse_auth_flags(["--localhost", "--rotate"], "auth ai provision", allow: ["--rotate"])
    assert_equal [false, {}], parse_auth_flags([], "auth ai provision", allow: ["--rotate"])
  end

  def test_parse_auth_flags_rejects_a_flag_the_command_does_not_take
    out, status = capture_stderr_and_exit { parse_auth_flags(["--rotate"], "auth ai clear") }
    assert_equal 1, status
    assert_match(/Unknown argument: --rotate/, out)
  end
end
