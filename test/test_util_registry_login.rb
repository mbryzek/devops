#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'

class TestUtilRegistryLogin < Minitest::Test
  def test_runs_doctl_registry_login
    cmds = []
    Util.stub(:assert_installed, nil) do
      Util.stub(:run, ->(cmd, *) { cmds << cmd }) do
        Util.registry_login
      end
    end
    assert_equal ["doctl registry login"], cmds
  end

  # Guard the core intent: we deliberately mint a short-lived (30-day default)
  # credential, never a forever token.
  def test_never_passes_never_expire
    cmds = []
    Util.stub(:assert_installed, nil) do
      Util.stub(:run, ->(cmd, *) { cmds << cmd }) do
        Util.registry_login
      end
    end
    refute_includes cmds.join(" "), "--never-expire"
  end

  def test_requires_doctl_installed
    checked = []
    Util.stub(:assert_installed, ->(cmd, *) { checked << cmd }) do
      Util.stub(:run, nil) do
        Util.registry_login
      end
    end
    assert_includes checked, "doctl"
  end
end
