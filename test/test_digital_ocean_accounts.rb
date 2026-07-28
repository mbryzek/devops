#!/usr/bin/env ruby
require_relative 'test_helper'
require_relative '../lib/common'

# DO account resolution (lib/do_accounts.rb): the label -> account map that
# routes doctl/kubectl/registry/bastion per app after the playbook account
# split. Parsing goes through a fixture pkl so the tests do not depend on the
# env repo checkout.
class TestDigitalOceanAccounts < Minitest::Test
  include DevTestSupport

  FIXTURE = File.expand_path('fixtures/digital-ocean-accounts.pkl', __dir__)

  def test_resolves_a_configured_label
    acct = DigitalOceanAccounts.for_label('personal', path: FIXTURE)
    assert_equal 'default', acct['doctl_context']
    assert_equal 'registry.digitalocean.com/bryzek', acct['registry']
    assert_equal 'bryzek-production', acct['namespace']
  end

  # The second account can be configured before its cluster/bastion exist:
  # nullable fields come through as nil, which activation/release-db treat as
  # "not provisioned yet" rather than an error at parse time.
  def test_unprovisioned_account_fields_are_nil
    acct = DigitalOceanAccounts.for_label('playbook', path: FIXTURE)
    assert_nil acct['kube_context']
    assert_nil acct['bastion']
  end

  def test_unknown_label_exits_listing_configured_labels
    err, status = capture_stderr_and_exit { DigitalOceanAccounts.for_label('nope', path: FIXTURE) }
    assert_equal 1, status
    assert_includes err, "No entry for DigitalOcean account 'nope'"
    assert_includes err, 'personal'
    assert_includes err, 'playbook'
  end

  # The KUBECONFIG stub's whole job: select current-context without touching
  # the user's real kubeconfig.
  def test_kube_stub_sets_only_current_context
    content = DigitalOceanAccounts.stub_content('do-nyc3-bryzek-cluster')
    assert_includes content, 'current-context: do-nyc3-bryzek-cluster'
    refute_includes content, 'clusters:'
  end
end

# App-level account + repo routing (lib/app.rb) that the split relies on.
class TestAppDoAccount < Minitest::Test
  def app(json_data)
    App.new({ 'name' => 'playbook-api', 'port' => 9300 }.merge(json_data))
  end

  def test_defaults_to_personal
    assert_equal 'personal', app({}).digital_ocean_account
  end

  def test_uses_the_configured_account
    assert_equal 'playbook', app('digital_ocean_account' => 'playbook').digital_ocean_account
  end

  # release-db keys multi-database target selection off this: platform and
  # playbook-api are both built from ~/code/platform, so a platform-postgresql
  # release must find both.
  def test_built_from_matches_shared_repo
    assert app('repo' => 'mbryzek/platform').built_from?('platform')
    refute app('repo' => 'mbryzek/platform').built_from?('playbook-api')
    assert app({ 'name' => 'platform' }).built_from?('platform')
  end
end
