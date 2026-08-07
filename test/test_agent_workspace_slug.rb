#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/agent/workspace'
require_relative '../lib/agent/gc'

# The slug is checked at USE, not merely asserted at mint.
#
# `Workspace.create` used to mkdir_p whatever it was handed while `delete`
# guarded — an asymmetry with nothing behind it. And not every slug reaching
# `create` comes from `Workspace.slug`: resuming a prior attempt passes
# `lease["branch"]` straight through (Tick#claim), which is a value the PLATFORM
# supplied. Today that value always originated here, but nothing on this side
# enforced it, and what the unchecked path does is mkdir_p — and later rm_rf — a
# caller-controlled path under the developer's own ~/code/ai.
#
# Deliberately its own file: test_agent_workspace_repos.rb stubs
# `Workspace.create` in setup, so these would exercise the stub rather than the
# guard.
class TestAgentWorkspaceSlug < Minitest::Test
  include DevTestSupport

  def with_workspace_root
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_WORKSPACE_ROOT"]
      ENV["DEV_AGENT_WORKSPACE_ROOT"] = root
      begin
        yield root
      ensure
        ENV["DEV_AGENT_WORKSPACE_ROOT"] = original
      end
    end
  end

  def test_a_generated_slug_is_accepted
    assert Agent::Workspace.valid_slug?(Agent::Workspace.slug(120))
    assert Agent::Workspace.valid_slug?(Agent::Workspace.slug(700, parent_number: 682, child_index: 7))
  end

  # Every workspace minted before ISS-767 is on this shape, and a machine can be
  # holding one for up to WORKSPACE_DAYS. It has to stay admitted or it falls
  # outside BOTH collectors at once: invisible to `Agent::Gc`, and no longer
  # skipped by the aggressive `dev aidirs prune`.
  def test_a_pre_iss767_random_slug_is_still_accepted
    assert Agent::Workspace.valid_slug?("i120_x4q")
    with_workspace_root do
      dir = Agent::Workspace.create("i120_x4q")
      assert File.directory?(dir)
      assert Agent::Workspace.delete("i120_x4q")
    end
  end

  def test_a_traversing_slug_is_refused_rather_than_materialized
    with_workspace_root do |root|
      assert_raises(RuntimeError) { Agent::Workspace.create("../../etc/pwned") }
      assert_empty Dir.children(root), "nothing may be created outside the workspace root"
    end
  end

  # 19 characters is the ceiling CLAUDE.md documents, because macOS caps a unix
  # socket path at 104 bytes and sbt builds its socket underneath the feature
  # dir. Past it sbt simply cannot start — it does not fail loudly — which is
  # why this is re-checked at use and not only inside the generator.
  def test_an_over_long_slug_is_refused
    long = "i123456789012345_abc"
    assert_equal 20, long.length
    refute Agent::Workspace.valid_slug?(long)
    with_workspace_root { assert_raises(RuntimeError) { Agent::Workspace.create(long) } }
  end

  # `i120` is deliberately absent from this list since ISS-767: it is the
  # standalone form the executor mints, so it MUST read as an executor slug. A
  # hand-made feature dir is named after its FEATURE — nothing here is a bare `i`
  # and a number, which is the whole reason that widening is safe.
  def test_a_hand_made_feature_dir_name_is_not_mistaken_for_an_executor_slug
    ["wk-devops-0805", "iss226-rev-src", "i120_ABC", "i120_ab", "i120-c07", "i_c07",
     "i682_c07_sig", "", nil].each do |name|
      refute Agent::Workspace.valid_slug?(name), "#{name.inspect} must not read as an executor slug"
    end
  end

  def test_delete_refuses_a_slug_it_could_not_have_created
    with_workspace_root do |root|
      victim = File.join(root, "mikes-own-work")
      FileUtils.mkdir_p(victim)
      refute Agent::Workspace.delete("mikes-own-work")
      assert File.directory?(victim), "delete must not remove a directory it did not create"
    end
  end

  def test_delete_still_removes_a_real_workspace
    with_workspace_root do
      dir = Agent::Workspace.create("i120_abc")
      assert File.directory?(dir)
      assert Agent::Workspace.delete("i120_abc")
      refute File.directory?(dir)
    end
  end

  # One pattern, defined at the producer. Two copies could drift into a gc that
  # either misses real workspaces or matches a hand-made feature dir — and gc
  # runs unattended with rm -rf over ~/code/ai.
  def test_gc_matches_exactly_what_workspace_mints
    assert_equal Agent::Workspace::SLUG, Agent::Gc::AGENT_SLUG
  end
end
