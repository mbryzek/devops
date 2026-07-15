#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'

class TestCloudflareDeploy < Minitest::Test
  def deploy(json_data)
    CloudflareDeploy.new(json_data)
  end

  # The common case: no pages_project configured, so the Pages project is the app's own
  # name. Guards the core intent — release-sveltekit must always be able to name a project
  # rather than leaving `wrangler pages deploy` to prompt.
  def test_defaults_to_app_name
    target = deploy('cloudflare_account' => 'personal')
    assert_equal "properties", target.pages_project_for("properties")
  end

  # A mirror target (clubaid-www -> plybk-www) deploys to a project that is not named after
  # the app; the explicit value must win over the default.
  def test_explicit_pages_project_wins
    target = deploy('cloudflare_account' => 'playbook', 'pages_project' => 'plybk-www')
    assert_equal "plybk-www", target.pages_project_for("clubaid-www")
  end

  def test_never_returns_nil
    refute_nil deploy('cloudflare_account' => 'personal').pages_project_for("michaelbryzek")
  end
end
