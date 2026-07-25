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

  # A mirror target (playbook-www -> plybk-www) deploys to a project that is not named after
  # the app; the explicit value must win over the default. The same pin is what keeps the
  # primary target on the pre-rename project name when an app is renamed.
  def test_explicit_pages_project_wins
    target = deploy('cloudflare_account' => 'playbook', 'pages_project' => 'plybk-www')
    assert_equal "plybk-www", target.pages_project_for("playbook-www")
  end

  def test_never_returns_nil
    refute_nil deploy('cloudflare_account' => 'personal').pages_project_for("michaelbryzek")
  end
end

# An app can be rebranded ahead of its GitHub repo. Everything filesystem- or
# git-facing keys off the repo, so `repo_name` must win over `name` when they differ.
class TestAppRepoName < Minitest::Test
  def app(json_data)
    App.new({ 'name' => 'playbook-www', 'port' => 80 }.merge(json_data))
  end

  def test_defaults_to_the_app_name
    assert_equal "playbook-www", app({}).repo_name
  end

  def test_uses_the_configured_repo
    assert_equal "legacy-www", app('repo' => 'mbryzek/legacy-www').repo_name
  end

  def test_ignores_an_empty_repo
    assert_equal "playbook-www", app('repo' => '').repo_name
  end
end
