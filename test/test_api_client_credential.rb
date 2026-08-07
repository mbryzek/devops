#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require_relative '../lib/api_client'

# `ApiClient.credential_for?` -- "can this process authenticate as `app` at all?"
#
# It exists because the two credentials are not interchangeable and asking for only one of them
# reads as correct. A Claude session authenticates with the AI's API token and has NO session file,
# so `session_id_for(...).nil?` is true for an identity that is perfectly well authenticated. Two
# call sites asked exactly that; one of them (`changelog_issue_map`) therefore skipped ISS
# enrichment on every agent-driven release and wrote the notes anyway, minus their issue links --
# a warning in the middle of a release nobody reads, and no other trace (ISS-736).
#
# NetworkGuard already stubs both accessors to nil suite-wide, so the no-credential case is the
# default here and each test opts back in to the arm it is about.
class TestApiClientCredential < Minitest::Test
  include DevTestSupport

  def with_credentials(auth_header: nil, session_id: nil)
    stub_singleton(ApiClient, :auth_header_for, ->(_app, use_localhost:) { auth_header }) do
      stub_singleton(ApiClient, :session_id_for, ->(_app, use_localhost:) { session_id }) do
        yield
      end
    end
  end

  # The ISS-736 case: an autonomous session, holding the AI token, with no session file anywhere.
  def test_an_ai_token_with_no_session_file_is_a_credential
    with_credentials(auth_header: ["Authorization", "Basic dG9rOg=="]) do
      assert ApiClient.credential_for?("playbook", use_localhost: false)
    end
  end

  def test_a_human_session_with_no_ai_token_is_a_credential
    with_credentials(session_id: "sess-playbook") do
      assert ApiClient.credential_for?("playbook", use_localhost: false)
    end
  end

  def test_neither_is_not_a_credential
    with_credentials do
      refute ApiClient.credential_for?("playbook", use_localhost: false)
    end
  end

  # Both arms are consulted, so a box that has one of each still answers once.
  def test_both_is_still_a_credential
    with_credentials(auth_header: ["Authorization", "Basic dG9rOg=="], session_id: "sess-playbook") do
      assert ApiClient.credential_for?("platform", use_localhost: false)
    end
  end
end
