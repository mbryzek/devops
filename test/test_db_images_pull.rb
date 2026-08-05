#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# DbImages.pull is the step that hung for 25+ minutes in ISS-578, producing no
# output and no failure, and taking a whole agent run with it.
class TestDbImagesPull < Minitest::Test
  include DevTestSupport

  IMAGE = "registry.digitalocean.com/bryzek/platformdb:0.5.61".freeze

  # Run DbImages.pull with docker answered by `outcome`, recording the argv and
  # the credential scope that was asked for.
  def pull(outcome)
    scopes = []
    cmds = []
    result = nil
    stub_singleton(RegistryAuth, :authenticate!, ->(read_write:) { scopes << read_write; "/tmp/cfg" }) do
      stub_singleton(Util, :run_with_timeout, lambda { |cmd, **kwargs|
        cmds << { :cmd => cmd, :kwargs => kwargs }
        [nil, outcome]
      }) do
        result = DbImages.pull(IMAGE)
      end
    end
    [result, scopes, cmds]
  end

  def test_authenticates_pull_only_before_pulling
    _, scopes, cmds = pull(:ok)
    assert_equal [false], scopes, "a pull must not mint push credentials"
    assert_equal [["docker", "pull", IMAGE]], cmds.map { |c| c[:cmd] }
  end

  def test_success_is_true
    result, = pull(:ok)
    assert_equal true, result
  end

  # False, not an abort: the caller's next move is the self-heal build, because
  # a failed pull normally means the tag was never pushed.
  def test_a_failed_pull_returns_false_so_the_caller_can_self_heal
    result, = pull(:failed)
    assert_equal false, result
  end

  # THE distinction that matters. A timeout is a stalled transfer, NOT "the
  # image is not in the registry" — returning false here would send claude-db
  # into a multi-arch buildx build and a push of an image that already exists,
  # off the back of a network blip.
  def test_a_timeout_aborts_rather_than_reporting_the_image_missing
    err, status = capture_stderr_and_exit { pull(:timed_out) }
    assert_equal 1, status
    assert_includes err, "Timed out"
    assert_includes err, "docker pull #{IMAGE}"
  end

  def test_the_pull_is_bounded
    _, _, cmds = pull(:ok)
    assert_equal DbImages::PULL_TIMEOUT_SECONDS, cmds.first[:kwargs][:timeout_seconds]
  end
end
