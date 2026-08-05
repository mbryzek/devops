#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common'
require_relative 'test_helper'

# Where app config is read from (ISS-546).
#
# dist/ is gitignored generated output that only generate-json.rb can rebuild,
# and only from the git-crypt'd env repo — which an agent workspace may not
# unlock. So a fresh <workspace>/devops clone has no dist/ at all and every bin/
# script that touches app config died on its first lookup, meaning the devops
# tooling could not be RUN from the workspace a change to it must be developed
# in.
#
# The resolution is pure and tested here against temp directories: nothing below
# touches the real ~/code/devops/dist or shells out.
class TestConfigDistDir < Minitest::Test
  include DevTestSupport

  def with_dirs
    Dir.mktmpdir do |root|
      local = File.join(root, "clone", "dist")
      canonical = File.join(root, "canonical", "dist")
      yield local, canonical
    end
  end

  def populate(dir, apps = %w[platform acumen])
    FileUtils.mkdir_p(dir)
    apps.each { |a| File.write(File.join(dir, "#{a}.config.json"), %({"app":{"name":"#{a}"}})) }
    dir
  end

  # ── the normal case: a checkout with its own generated dist/ ──────────────

  def test_local_dist_wins_when_it_has_configs
    with_dirs do |local, canonical|
      populate(local)
      populate(canonical)
      assert_equal local, Config.resolve_dist_dir(local, canonical)
    end
  end

  # A deploy box ships a prebuilt dist/ inside the artifact and has no env
  # checkout either. If a developer checkout on the same box could override it,
  # a release would silently deploy against someone's working copy.
  def test_local_dist_wins_even_when_canonical_is_also_populated_and_differs
    with_dirs do |local, canonical|
      populate(local, %w[platform])
      populate(canonical, %w[platform acumen workers])
      assert_equal local, Config.resolve_dist_dir(local, canonical)
    end
  end

  # ── the workspace clone: no dist/, no env repo to rebuild it ──────────────

  def test_falls_back_to_canonical_when_local_is_absent
    with_dirs do |local, canonical|
      populate(canonical)
      refute File.directory?(local)
      assert_equal canonical, Config.resolve_dist_dir(local, canonical)
    end
  end

  # `mkdir dist` without a successful pkl eval is the half-created state
  # generate-json.rb can leave behind. Existing is not the same as usable.
  def test_falls_back_when_local_exists_but_holds_no_configs
    with_dirs do |local, canonical|
      FileUtils.mkdir_p(local)
      populate(canonical)
      assert_equal canonical, Config.resolve_dist_dir(local, canonical)
    end
  end

  # ── nothing anywhere ──────────────────────────────────────────────────────

  # Returning local keeps Config.load's "File '...' not found" naming the path
  # the caller expected, rather than pointing at a checkout they are not in.
  def test_returns_local_when_neither_has_configs
    with_dirs do |local, canonical|
      assert_equal local, Config.resolve_dist_dir(local, canonical)
    end
  end

  # The canonical checkout IS the local one whenever the CLI runs from
  # ~/code/devops. The fallback must not present itself as a source there.
  def test_identical_paths_never_report_a_fallback
    with_dirs do |local, _canonical|
      assert_equal local, Config.resolve_dist_dir(local, local)
    end
  end

  # ── configured_dist? ──────────────────────────────────────────────────────

  def test_configured_dist_ignores_non_config_files
    with_dirs do |local, _canonical|
      FileUtils.mkdir_p(local)
      File.write(File.join(local, "README.md"), "not a config")
      refute Config.configured_dist?(local)
    end
  end

  def test_configured_dist_handles_a_missing_directory
    with_dirs do |local, _canonical|
      refute Config.configured_dist?(local)
    end
  end

  # ── the notice ────────────────────────────────────────────────────────────

  def announce(dir)
    Config.instance_variable_set(:@announced_dist_fallback, false)
    capture_io { Config.announce_dist_fallback(dir) }
  ensure
    Config.instance_variable_set(:@announced_dist_fallback, false)
  end

  # The same failure test/env-stdout-is-evalable.sh guards: `bin/env --format sh`
  # has its stdout eval'd by the caller, and bin/db emits a bare URL. A banner on
  # stdout there fails with "==: command not found".
  def test_the_fallback_notice_goes_to_stderr_not_stdout
    out, err = announce("/somewhere/dist")
    assert_equal "", out
    assert_includes err, "/somewhere/dist"
  end

  # Config.dist_dir is called on every load and every Config.all; one line per
  # process, not one per lookup.
  def test_the_fallback_notice_is_printed_once_per_process
    Config.instance_variable_set(:@announced_dist_fallback, false)
    first = capture_io { Config.announce_dist_fallback("/somewhere/dist") }
    second = capture_io { Config.announce_dist_fallback("/somewhere/dist") }
    refute_equal "", first[1]
    assert_equal "", second[1]
  ensure
    Config.instance_variable_set(:@announced_dist_fallback, false)
  end

  # ── wiring: the constants dist_dir is actually built from ─────────────────

  def test_local_dist_dir_is_this_checkouts_own_dist
    assert_equal File.expand_path("../dist", __dir__), Config.local_dist_dir
  end

  def test_canonical_dist_dir_is_the_code_checkout
    assert_equal File.expand_path("~/code/devops/dist"), Config::CANONICAL_DIST_DIR
  end
end
