#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/api_client'

# How `ApiClient` words a 401.
#
# Before ISS-474 every 401 produced the same sentence -- "Session expired or invalid ... Run 'dev
# auth login'" -- and the response body was discarded. An autonomous session authenticates as Otto
# AI with an API token and has no session and no terminal, so on the two calls the agent briefing
# opens an investigation with (`dev queries top`, `dev invariants check`) it was told to run an
# interactive login it cannot run, about a credential it was not using, while the server had
# actually said `User ai does not belong to platform`. It read as a routine auth hiccup and the runs
# still produced plausible reports, so nobody noticed for months.
#
# The contract these pin: the server's own words always survive, and the remedy is chosen from the
# credential that actually went out -- never from pattern-matching the server's text, which the
# platform is free to reword.
class TestApiClientUnauthorized < Minitest::Test
  UNAUTHORIZED_BODY = '{"discriminator":"unauthorized","message":"User ai does not belong to platform"}'.freeze

  # Named `unauthorized_for`, not `message`: Minitest::Assertions defines its own `message`, and
  # shadowing it makes every assertion in the file blow up before it can report anything.
  def unauthorized_for(credential:, body: UNAUTHORIZED_BODY, use_localhost: false)
    ApiClient.unauthorized_message(
      credential: credential,
      endpoint: { app: "platform" },
      use_localhost: use_localhost,
      login_cmd: "dev auth login",
      body: body,
    )
  end

  def test_ai_token_401_never_advises_an_interactive_login
    msg = unauthorized_for(credential: :ai_token)
    refute_includes msg, "Run 'dev auth login'"
    refute_includes msg, "Session expired"
    assert_includes msg, "Otto AI"
    assert_includes msg, "dev auth ai provision --rotate"
  end

  # The whole point: the body already says whether this is authn or authz, so it has to reach the
  # human (or the session) reading the failure.
  def test_the_servers_own_message_survives
    [:ai_token, :session, :explicit_token].each do |credential|
      assert_includes unauthorized_for(credential: credential), "User ai does not belong to platform"
    end
  end

  def test_session_401_still_advises_a_login
    msg = unauthorized_for(credential: :session)
    assert_includes msg, "Session expired or invalid"
    assert_includes msg, "Run 'dev auth login'"
  end

  def test_explicit_token_401_blames_the_token_presented
    assert_includes unauthorized_for(credential: :explicit_token), "API token presented for this call was rejected"
  end

  def test_localhost_is_named_in_the_target_and_the_remedy
    msg = unauthorized_for(credential: :ai_token, use_localhost: true)
    assert_includes msg, "platform (localhost)"
    assert_includes msg, "dev auth ai provision --rotate --localhost"
  end

  # A proxy or load balancer can 401 with HTML, and an empty body is legal. Neither may crash the
  # error path -- this runs only when something has already gone wrong.
  def test_a_non_envelope_body_is_quoted_verbatim
    assert_includes unauthorized_for(credential: :session, body: "<html>401 Unauthorized</html>"),
                    "<html>401 Unauthorized</html>"
  end

  def test_an_empty_body_omits_the_clause_entirely
    msg = unauthorized_for(credential: :session, body: "")
    refute_includes msg, "server said"
    assert_includes msg, "Run 'dev auth login'"
  end

  def test_an_envelope_with_no_message_falls_back_to_the_raw_body
    assert_includes unauthorized_for(credential: :session, body: '{"discriminator":"unauthorized"}'),
                    '{"discriminator":"unauthorized"}'
  end

  # The identity has to be resolvable from the library alone. It used to be a top-level constant in
  # `bin/dev`, which every other entry point requiring this file would have hit as a NameError -- on
  # the error path, the one that ships unexercised.
  def test_the_ai_identity_is_reachable_without_loading_bin_dev
    assert_equal "ai", ApiClient::AI_USER_ID
    assert_equal "Otto AI", ApiClient::AI_USER_LABEL
  end
end
