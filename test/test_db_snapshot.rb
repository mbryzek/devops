#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tempfile'
require_relative '../lib/common'
require_relative 'test_helper'

# The baseline is cut from a PRODUCTION snapshot, so this filter is the only
# thing standing between real customer rows and an image that gets pushed to a
# shared registry and cloned into every Claude session. A bug here is a data
# leak, not a build failure — which is why it is a pure function over a stream
# with its own tests rather than a shell pipeline inside the build script.
class TestDbSnapshot < Minitest::Test
  include DevTestSupport

  # A miniature pg_dump: schema statements, a COPY block of application data,
  # and a COPY block of SEM tracking rows.
  DUMP = <<~SQL
    SET statement_timeout = 0;
    CREATE TABLE public.users (id text, email text);
    ALTER SCHEMA public OWNER TO postgres;
    COPY public.users (id, email) FROM stdin;
    usr-1\treal.person@example.com
    usr-2\tanother.person@example.com
    \\.
    CREATE INDEX users_pkey ON public.users (id);
    COPY schema_evolution_manager.scripts (id, filename) FROM stdin;
    1\t20240101-000000.sql
    \\.
    ALTER TABLE public.users OWNER TO api;
  SQL

  def run_filter(keep)
    out = StringIO.new
    Tempfile.create("snapshot") do |f|
      f.write(DUMP)
      f.flush
      kept, dropped = DbSnapshot.stream_schema_only(f.path, keep, out)
      return [out.string, kept, dropped]
    end
  end

  def test_application_data_never_reaches_the_output
    result, _kept, dropped = run_filter(DbSnapshot::SCHEMA_STATE_TABLES)
    refute_includes result, "real.person@example.com"
    refute_includes result, "another.person@example.com"
    refute_includes result, "COPY public.users"
    assert_equal 1, dropped
  end

  def test_schema_statements_are_preserved
    result, _kept, _dropped = run_filter(DbSnapshot::SCHEMA_STATE_TABLES)
    assert_includes result, "CREATE TABLE public.users"
    assert_includes result, "CREATE INDEX users_pkey"
    assert_includes result, "ALTER TABLE public.users OWNER TO api;"
  end

  # Without the tracking rows, sem-apply believes nothing has ever been applied
  # and replays the entire script history against an already-full schema.
  def test_sem_tracking_rows_are_kept
    result, kept, _dropped = run_filter(DbSnapshot::SCHEMA_STATE_TABLES)
    assert_includes result, "COPY schema_evolution_manager.scripts"
    assert_includes result, "20240101-000000.sql"
    assert_equal ["schema_evolution_manager.scripts"], kept
  end

  # The restore runs against a database owned by the application role, which
  # cannot assign ownership to postgres ("must be able to SET ROLE").
  def test_unrestorable_public_schema_owner_line_is_dropped
    result, _kept, _dropped = run_filter(DbSnapshot::SCHEMA_STATE_TABLES)
    refute_includes result, "ALTER SCHEMA public OWNER TO postgres"
  end

  # Resuming after a skipped COPY depends on spotting the terminator; getting
  # that wrong swallows the rest of the schema silently.
  def test_skipping_resumes_after_the_copy_terminator
    result, _kept, _dropped = run_filter([])
    assert_includes result, "CREATE INDEX users_pkey"
    assert_includes result, "ALTER TABLE public.users OWNER TO api;"
    refute_includes result, "20240101-000000.sql"
  end

  def test_copy_target_parsing
    assert_equal "public.users",
                 DbSnapshot.copy_target("COPY public.users (id, email) FROM stdin;\n")
    assert_equal "journal.settings",
                 DbSnapshot.copy_target(%(COPY "journal"."settings" (id) FROM stdin;\n))
    assert_nil DbSnapshot.copy_target("CREATE TABLE public.users (id text);\n")
    # A column literally named "copy" in a CREATE must not be mistaken for one.
    assert_nil DbSnapshot.copy_target("  COPY public.users FROM stdin;\n")
  end
end

# A registry repository that has never been pushed to does not exist at all, and
# doctl reports that as a 404. Treating it as a hard failure meant a brand-new
# app could never be healed by verify-db-images — the one situation it exists
# for. Treating EVERY doctl failure as "absent" would be worse: a network outage
# would read as an empty registry and trigger a rebuild.
class TestDbImagesRepositoryMissing < Minitest::Test
  include DevTestSupport

  def test_404_repository_not_found_is_absent_not_an_error
    out = '{"errors":[{"detail":"GET https://api.digitalocean.com/v2/registry/bryzek/repositories/acumendb/tags: 404 repository not found"}]}'
    assert DbImages.repository_missing?(out)
  end

  def test_other_failures_are_not_treated_as_absent
    refute DbImages.repository_missing?('Error: unable to connect to the API')
    refute DbImages.repository_missing?('Error: 401 Unauthorized')
    refute DbImages.repository_missing?('')
  end
end
