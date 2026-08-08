#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::ProductOwner — the stored logins the daily `product-owner` producer
# uses to review the products as a real user.
#
# Like Agent::ClaudeConfig, every assertion here is about a SILENCE. Nothing
# fails loudly when this file is wrong: the producer still fires, the session
# still starts, and it simply cannot log in — so it reports the product as
# unreachable rather than reporting the credential as missing. These tests pin
# the states that silence hides, and pin that the check never writes.
class TestDevAgentProductOwner < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |dir|
      original = ENV["DEV_AGENT_STATE_DIR"]
      ENV["DEV_AGENT_STATE_DIR"] = dir
      begin
        yield dir
      ensure
        ENV["DEV_AGENT_STATE_DIR"] = original
      end
    end
  end

  def write_creds(contents, mode: 0o600)
    file = Agent::ProductOwner.path
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, contents.is_a?(String) ? contents : JSON.generate(contents))
    File.chmod(mode, file)
    file
  end

  def valid_payload
    { "acumen" => { "url" => "https://www.trueacumen.com",
                    "username" => "someone@example.com",
                    "password" => "hunter2" } }
  end

  def test_ok_when_present_private_and_complete
    with_state_dir do
      write_creds(valid_payload)
      state = Agent::ProductOwner.state
      assert state.ok?, "expected ok, got #{state.state}: #{state.message}"
      assert_nil state.remedy
    end
  end

  def test_absent_reports_a_command_to_create_it
    with_state_dir do
      state = Agent::ProductOwner.state
      assert_equal :absent, state.state
      refute state.ok?
      assert_includes state.remedy, "umask 077"
    end
  end

  # A world-readable secret has already been exposed. The check must say so and
  # must NOT quietly chmod it, or the person who needs to rotate it never finds
  # out it leaked.
  def test_loose_permissions_are_reported_and_never_corrected
    with_state_dir do
      file = write_creds(valid_payload, mode: 0o644)
      state = Agent::ProductOwner.state
      assert_equal :bad_mode, state.state
      assert_includes state.remedy, "chmod 600"
      assert_equal "0644", format("%04o", File.stat(file).mode & 0o7777),
                   "state must not change the file it inspects"
    end
  end

  def test_malformed_json_is_distinguished_from_absent
    with_state_dir do
      write_creds("{ not json")
      state = Agent::ProductOwner.state
      assert_equal :malformed, state.state
      assert_includes state.remedy, "not valid JSON"
    end
  end

  def test_missing_required_app_is_incomplete
    with_state_dir do
      write_creds({ "playbook" => { "username" => "u", "password" => "p" } })
      state = Agent::ProductOwner.state
      assert_equal :incomplete, state.state
      assert_includes state.missing, "acumen"
      assert_includes state.remedy, "acumen"
    end
  end

  # An entry with a blank password is worse than no entry: the session attempts
  # a login, fails, and blames the product instead of the credential.
  def test_blank_password_counts_as_missing
    with_state_dir do
      write_creds({ "acumen" => { "username" => "u", "password" => "   " } })
      assert_equal :incomplete, Agent::ProductOwner.state.state
    end
  end

  # Playbook mints a login token from the AI token instead of storing a
  # password, so it must never be required here.
  def test_playbook_is_not_a_required_app
    refute_includes Agent::ProductOwner::REQUIRED_APPS, "playbook"
  end
end
