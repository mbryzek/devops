#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require_relative '../lib/depsguard'

# `dev depsguard` — the scan's verdict IS its exit code, so these tests are about
# the two things that can silently go wrong: suppressing a failure that was real,
# and reporting a clean scan when the scanner never ran.
#
# Ported from openclaw-workspace/scripts/depsguard-wrapped, which had no tests at
# all. The suppression rule below is the one that mattered: an earlier auto-fixer
# kept adding pnpm's `minimum-release-age` to npm-only repos, producing endless
# add/revert churn on apibuilder-ui's .npmrc.
class TestDepsguard < Minitest::Test
  include DevTestSupport

  # A File stand-in so npm-only detection can be exercised without a filesystem.
  class FakeFs
    def initialize(existing) = @existing = existing
    def exist?(path) = @existing.include?(path)
  end

  NPM_ONLY = FakeFs.new(["/repo/package-lock.json"]).freeze
  PNPM_REPO = FakeFs.new(["/repo/package-lock.json", "/repo/pnpm-lock.yaml"]).freeze

  def scan(stdout, stderr: "", success: true, exitstatus: 0)
    status = Struct.new(:success?, :exitstatus).new(success, exitstatus)
    Depsguard.run(capture: -> { [stdout, stderr, status] }, fs: NPM_ONLY)
  end

  # ---- classification ----

  def test_pnpm_release_age_on_npm_only_repo_is_suppressed
    out = <<~OUT
      Config: /repo/.npmrc
        ✗ (pnpm) minimum-release-age not set
    OUT
    real, suppressed = Depsguard.classify(out, fs: NPM_ONLY)
    assert_empty real
    assert_equal 1, suppressed.length
  end

  def test_same_failure_on_a_pnpm_repo_is_real
    out = <<~OUT
      Config: /repo/.npmrc
        ✗ (pnpm) minimum-release-age not set
    OUT
    real, suppressed = Depsguard.classify(out, fs: PNPM_REPO)
    assert_equal 1, real.length
    assert_empty suppressed
  end

  def test_other_failures_on_an_npm_only_repo_still_surface
    out = <<~OUT
      Config: /repo/.npmrc
        ✗ (npm) ignore-scripts not set
        ✗ (pnpm) minimum-release-age not set
    OUT
    real, suppressed = Depsguard.classify(out, fs: NPM_ONLY)
    assert_equal 1, real.length
    assert_includes real.first.last, "ignore-scripts"
    assert_equal 1, suppressed.length
  end

  # The global ~/.npmrc governs every npm invocation on the machine, so its
  # failures must always surface — even though $HOME here happens to hold a stray
  # package-lock.json, which would otherwise make it look npm-only.
  def test_home_npmrc_is_never_treated_as_npm_only
    fs = FakeFs.new([File.join(Dir.home, "package-lock.json")])
    refute Depsguard.npm_only_npmrc?(File.join(Dir.home, ".npmrc"), fs: fs)
  end

  def test_ansi_colour_codes_do_not_hide_a_failure
    out = "Config: /repo/.npmrc\n  \e[31m✗\e[0m (npm) ignore-scripts not set\n"
    real, = Depsguard.classify(Depsguard.strip_ansi(out), fs: NPM_ONLY)
    assert_equal 1, real.length
  end

  # ---- the exit-code contract ----

  def test_clean_scan_exits_zero
    result = scan("Config: /repo/.npmrc\n  ✓ (npm) ignore-scripts set\n")
    assert_equal 0, result.exit_code
    assert_includes result.lines.join("\n"), "All depsguard checks pass"
  end

  def test_real_failures_exit_one_and_are_listed
    result = scan("Config: /repo/.npmrc\n  ✗ (npm) ignore-scripts not set\n")
    assert_equal 1, result.exit_code
    assert_includes result.lines.join("\n"), "ignore-scripts"
  end

  def test_only_suppressed_failures_still_exit_zero
    result = scan("Config: /repo/.npmrc\n  ✗ (pnpm) minimum-release-age not set\n")
    assert_equal 0, result.exit_code
  end

  # A scanner that could not run is NOT evidence that the configs are fine. Exit
  # 2 keeps `check_failed` distinct from `filed` so a broken binary does not
  # become a weekly stream of bogus issues.
  def test_missing_binary_exits_two
    result = Depsguard.run(capture: -> { [nil, nil, nil] }, fs: NPM_ONLY)
    assert_equal 2, result.exit_code
    assert_includes result.lines.join("\n"), "not found in PATH"
  end

  def test_scan_crash_with_no_output_exits_two
    result = scan("", stderr: "boom", success: false, exitstatus: 3)
    assert_equal 2, result.exit_code
    assert_includes result.lines.join("\n"), "exit 3"
  end

  # depsguard 0.1.33 always exits 0. If a future version signals trouble via a
  # nonzero exit while printing no parseable failure, that must not read as a
  # clean scan.
  def test_nonzero_exit_with_no_parsed_failures_exits_two
    result = scan("Config: /repo/.npmrc\n  ✓ all good\n", stderr: "warning", success: false, exitstatus: 9)
    assert_equal 2, result.exit_code
  end
end
