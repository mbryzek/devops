#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'

# The session-DB image recipe has now shipped three separate "Permission denied"
# outages, all of the same shape: a file or directory mode that root can use and
# the postgres user cannot, invisible until a container ran initdb minutes or
# days later — by which point the broken image was in the registry under a tag
# that never moves again (DbImages.image_tag is the schema tag verbatim).
#
#   0600 artifacts        a build host with umask 077 → fixed by COPY --chmod=644
#   0711 init script      `chmod +x` on a 0600 source → fixed by COPY --chmod=755
#   0644 /schema DIR      COPY creating the parent implicitly, inheriting the
#                         file's --chmod → ISS-139 (acumendb 0.1.53) and ISS-156
#                         (platformdb 0.5.34-0.5.37)
#
# These assert the two things that keep the class of bug from coming back: the
# directory's mode is stated rather than inherited, and the build itself reads
# every baked file AS postgres, so a mode regression fails `db-image build`
# instead of the container start of whoever pulls the tag.
class TestDbImageDockerfile < Minitest::Test
  include DevTestSupport

  DOCKERFILE = File.read(File.expand_path('../db-image/Dockerfile', __dir__))

  def test_schema_directory_mode_is_explicit_not_inherited_from_copy
    assert_match(/RUN mkdir -p \/schema && chmod 755 \/schema/, DOCKERFILE,
                 "/schema must be created with an explicit 0755. Left to COPY, the " \
                 "directory inherits the file's --chmod (0644) and has no execute " \
                 "bit, so postgres cannot traverse into it (ISS-139 / ISS-156).")
  end

  def test_schema_directory_is_created_before_anything_is_copied_into_it
    mkdir = DOCKERFILE.index("mkdir -p /schema")
    copy  = DOCKERFILE.index("COPY --chmod=644 schema.sql")
    refute_nil mkdir
    refute_nil copy
    assert mkdir < copy,
           "The mkdir must precede the COPYs — after them the directory already " \
           "exists with the wrong mode and COPY will not change it."
  end

  def test_build_reads_every_baked_file_as_the_postgres_user
    assert_match(/RUN su postgres/, DOCKERFILE,
                 "The build must read the baked files as postgres. Root can read " \
                 "everything, so no root-run check can catch a mode that locks out " \
                 "the user the entrypoint actually runs as.")
    assert_match(/\/schema\/\*\.sql/, DOCKERFILE)
    assert_match(/\/docker-entrypoint-initdb.d\/10-schema\.sh/, DOCKERFILE)
  end

  def test_readability_check_runs_after_every_copy
    check = DOCKERFILE.index("RUN su postgres")
    last_copy = DOCKERFILE.rindex("COPY ")
    refute_nil check
    refute_nil last_copy
    assert check > last_copy,
           "The postgres-readability check must be the last instruction — a COPY " \
           "after it is a file the build never proved readable."
  end
end
