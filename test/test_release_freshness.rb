#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_helper'
load File.expand_path('../lib/common.rb', __dir__)

# ReleaseFreshness.ensure! — the guard bin/release runs before any stack
# script: never release a checkout behind origin/main; recover via
# fast-forward pull, error only when recovery isn't possible.
class TestReleaseFreshness < Minitest::Test
  include DevTestSupport

  def setup
    @root = Dir.mktmpdir
    @origin = File.join(@root, "origin.git")
    @clone = File.join(@root, "clone")
    sh "git init -q --bare --initial-branch=main #{@origin}"
    sh "git clone -q #{@origin} #{@clone}"
    sh "git -C #{@clone} -c user.email=t@t -c user.name=t commit -q --allow-empty -m one"
    sh "git -C #{@clone} push -q origin main"
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def sh(cmd)
    out = `#{cmd} 2>&1`
    raise "setup command failed: #{cmd}\n#{out}" unless $?.success?
  end

  # Add a commit to origin/main that @clone does not have, via a second clone.
  def advance_origin
    other = File.join(@root, "other")
    sh "git clone -q #{@origin} #{other}"
    sh "git -C #{other} -c user.email=t@t -c user.name=t commit -q --allow-empty -m upstream"
    sh "git -C #{other} push -q origin main"
  end

  def capture_io
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def test_noop_when_current
    capture_io { ReleaseFreshness.ensure!(@clone) }
    assert_equal 0, `git -C #{@clone} rev-list --count HEAD..origin/main`.strip.to_i
  end

  def test_recovers_by_fast_forwarding_a_stale_checkout
    advance_origin
    out = capture_io { ReleaseFreshness.ensure!(@clone) }
    assert_match(/behind origin\/main; pulling/, out)
    sh "git -C #{@clone} fetch -q origin"
    assert_equal 0, `git -C #{@clone} rev-list --count HEAD..origin/main`.strip.to_i
  end

  def test_errors_when_diverged
    advance_origin
    sh "git -C #{@clone} -c user.email=t@t -c user.name=t commit -q --allow-empty -m local"
    _, status = capture_stderr_and_exit { capture_io { ReleaseFreshness.ensure!(@clone) } }
    refute_nil status, "expected exit when fast-forward is impossible"
  end

  def test_errors_off_main
    sh "git -C #{@clone} checkout -q -b feature"
    _, status = capture_stderr_and_exit { ReleaseFreshness.ensure!(@clone) }
    refute_nil status, "expected exit when not on main"
  end
end
