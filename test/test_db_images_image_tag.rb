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

  # Image ref and container naming are per app — see test_db_apps.rb.
end
