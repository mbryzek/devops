#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# The image tag IS the schema tag, and it is also what names the per-tag
# container — so these two must not drift apart. There used to be a recipe hash
# suffix (platform-postgresql's docker/image-tag.sh, now deleted); it is gone
# because a tag that moved without a schema release meant tearing down the one
# shared container, which destroyed every other session's database.
#
# The accepted regression: a recipe-only change (seed.sql, initdb, Dockerfile)
# does NOT move the tag, so it reaches nobody until the next schema tag bump.
# Mitigation is discipline, not code — nothing here should reintroduce a
# derived tag.
class TestDbImagesImageTag < Minitest::Test
  include DevTestSupport

  def test_image_tag_is_the_schema_tag_unchanged
    assert_equal "0.5.18", DbImages.image_tag("0.5.18")
  end

  def test_image_tag_does_not_shell_out
    # A shell-out is what made this fail whenever a checkout was stale. Prove it
    # is pure: no checkout on disk is consulted, so no checkout can break it.
    Dir.chdir("/") do
      assert_equal "0.9.99", DbImages.image_tag("0.9.99")
    end
  end

  def test_image_ref_is_registry_plus_schema_tag
    assert_equal(
      "registry.digitalocean.com/bryzek/platformdb:0.5.22",
      DbImages.image_ref(DbImages.image_tag("0.5.22"))
    )
  end

  # ── container naming ──────────────────────────────────────────────────────

  def test_container_name_is_prefix_plus_schema_tag
    assert_equal "platformdb-claude-0.5.22", DbImages.container_name("0.5.22")
  end

  def test_container_schema_tag_round_trips
    assert_equal "0.5.22", DbImages.container_schema_tag(DbImages.container_name("0.5.22"))
  end

  # The pre-split container carries no tag. It may still hold other sessions'
  # databases, so it has to be recognisable rather than mistaken for a tagged one.
  def test_legacy_container_has_no_schema_tag
    assert_nil DbImages.container_schema_tag(DbImages::LEGACY_CONTAINER)
  end

  def test_unrelated_container_has_no_schema_tag
    assert_nil DbImages.container_schema_tag("some-other-postgres")
  end
end
