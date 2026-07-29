#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# DigitalOcean enforces the repository cap when it issues the PUSH TOKEN — the
# last step of `docker buildx build --push`. So the failure arrives only after
# the scratch Postgres has run, the schema has been replayed and both
# architectures have built and exported their layers:
#
#   denied: registry contains 5 repositories, limit is 5
#
# `db-image build --push` therefore checks for room up front. What these tests
# pin down is that the check can only ever turn a GUARANTEED failure into a fast
# one: every uncertain case must wave the build through.
class TestDbImagesRegistryRoom < Minitest::Test
  include DevTestSupport

  StubApp = Struct.new(:image_name)

  def full_registry
    %w[acumen court-reserve-workers platform platformdb workers]
  end

  def assert_blocks(app, names)
    err, status = capture_stderr_and_exit do
      DbImages.assert_registry_has_room!(app, :names => names)
    end
    assert_equal 1, status, "expected the build to be blocked"
    err
  end

  def assert_allows(app, names)
    _, status = capture_stderr_and_exit do
      DbImages.assert_registry_has_room!(app, :names => names)
    end
    assert_nil status, "expected the build to proceed"
  end

  def test_blocks_a_new_repository_when_the_registry_is_full
    err = assert_blocks(StubApp.new("acumendb"), full_registry)
    assert_includes err, "Registry is full"
    assert_includes err, "acumendb"
  end

  def test_error_names_the_occupants_so_a_slot_can_be_freed
    err = assert_blocks(StubApp.new("acumendb"), full_registry)
    full_registry.each { |name| assert_includes err, name }
  end

  # The registry being full is irrelevant when no new slot is needed: pushing a
  # new TAG to a repository that already exists is what every routine build does.
  def test_allows_an_existing_repository_even_at_the_limit
    assert_allows(StubApp.new("platformdb"), full_registry)
  end

  def test_allows_a_new_repository_when_a_slot_is_free
    assert_allows(StubApp.new("acumendb"), full_registry - ["court-reserve-workers"])
  end

  # nil is "could not read the registry", which repository_names returns for a
  # doctl outage — indistinguishable on stdout from an empty registry. Blocking
  # here would ground every push whenever the network hiccups, so it fails open.
  def test_allows_when_the_listing_could_not_be_read
    assert_allows(StubApp.new("acumendb"), nil)
  end

  def test_allows_an_empty_registry
    assert_allows(StubApp.new("acumendb"), [])
  end
end
