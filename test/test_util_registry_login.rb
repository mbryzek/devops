#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

class TestUtilRegistryLogin < Minitest::Test
  include DevTestSupport

  def test_runs_doctl_registry_login
    cmds = []
    stub_singleton(Util, :assert_installed, ->(*) {}) do
      stub_singleton(Util, :run, ->(cmd, *) { cmds << cmd }) do
        Util.registry_login
      end
    end
    assert_equal ["doctl registry login"], cmds
  end

  # Guard the core intent: we deliberately mint a short-lived (30-day default)
  # credential, never a forever token.
  def test_never_passes_never_expire
    cmds = []
    stub_singleton(Util, :assert_installed, ->(*) {}) do
      stub_singleton(Util, :run, ->(cmd, *) { cmds << cmd }) do
        Util.registry_login
      end
    end
    refute_includes cmds.join(" "), "--never-expire"
  end

  def test_requires_doctl_installed
    checked = []
    stub_singleton(Util, :assert_installed, ->(cmd, *) { checked << cmd }) do
      stub_singleton(Util, :run, ->(*) {}) do
        Util.registry_login
      end
    end
    assert_includes checked, "doctl"
  end
end
