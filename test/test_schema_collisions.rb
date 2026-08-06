#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_helper'
require_relative '../lib/schema_collisions'

# Covers the from-scratch replay that decides whether a schema repo's scripts can
# be applied to a database built from nothing.
#
# THE REGRESSION BAR is the pair at the top: the two ISS-592 migrations, reduced
# but shaped exactly as they were merged — both under `set search_path to
# issues`, both naming their tables unqualified, from two branches that could not
# see each other. If that pair ever reads as clean again, `claude-db start` goes
# back to being the first thing in the system to notice, and it notices by
# halting sem for every migration behind it.
#
# The other direction costs more, which is why most of what follows is about it:
# a FALSE collision blocks a release AND every session's database. Each "no
# collision" case below is a real construct out of the 904 platform-postgresql
# scripts, and the whole file at main scans clean.
class TestSchemaCollisions < Minitest::Test
  # ISS-575, as merged by #506.
  INTAKE_A = <<~SQL
    create schema if not exists issues;
    set search_path to issues;
    create table issue_intake_senders(id text primary key, tenant_id text not null);
    create index issue_intake_senders_tenant_id_status_idx on issue_intake_senders(tenant_id, status);
    set search_path to public;
  SQL

  # ISS-576, as merged by #507 twenty-three seconds later, from a different draft
  # of the same DAO spec.
  INTAKE_B = <<~SQL
    create schema if not exists issues;
    set search_path to issues;
    create table issue_intake_senders(id text primary key, tenant_id text not null, note text);
    create index issue_intake_senders_tenant_id_status_idx on issue_intake_senders(tenant_id, status);
    set search_path to public;
  SQL

  def with_scripts(scripts)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      scripts.each { |name, sql| File.write(File.join(dir, "scripts", name), sql) }
      yield dir
    end
  end

  # One script's worth of statements replayed on a fresh state.
  def collisions(*sql)
    with_scripts(sql.each_with_index.to_h { |body, i| ["2026080#{i}-000000.sql", body] }) do |dir|
      return SchemaCollisions.scan(dir)
    end
  end

  # ---- the regression bar ---------------------------------------------------

  def test_two_branches_creating_the_same_tables_collide
    found = collisions(INTAKE_A, INTAKE_B)
    assert_equal %w[table index], found.map(&:kind)
    assert_equal ["issues.issue_intake_senders", "issues.issue_intake_senders_tenant_id_status_idx"],
                 found.map(&:name)
    assert_equal ["20260800-000000.sql"], found.map(&:first_script).uniq
    assert_equal ["20260801-000000.sql"], found.map(&:script).uniq
  end

  # Both scripts name the table unqualified under `set search_path to issues`.
  # Without the search_path they are two different tables and this reads clean.
  def test_the_search_path_is_what_makes_the_names_the_same
    assert_equal 1, collisions(
      "set search_path to issues; create table senders(id text);",
      "set search_path to issues; create table senders(id text);"
    ).length
  end

  def test_the_same_name_in_two_schemas_is_not_a_collision
    assert_empty collisions(
      "set search_path to issues; create table senders(id text);",
      "set search_path to sms; create table senders(id text);"
    )
  end

  def test_a_qualified_name_matches_an_unqualified_one_under_the_same_search_path
    assert_equal 1, collisions(
      "set search_path to issues; create table senders(id text);",
      "create table issues.senders(id text);"
    ).length
  end

  # Every script starts in public: sem-apply gives each one its own session, and
  # the house style is to `set search_path to public` on the way out.
  def test_search_path_does_not_leak_between_scripts
    assert_empty collisions(
      "set search_path to issues; create table senders(id text);",
      "create table senders(id text);"
    )
  end

  # ---- guards and re-runnable shapes ---------------------------------------

  # `drop table if exists x; create table x (...)` is how a large share of the
  # generated migrations open, and it is the fix ISS-592 shipped.
  def test_a_drop_before_the_create_is_not_a_collision
    assert_empty collisions(
      "set search_path to issues; create table senders(id text);",
      "set search_path to issues; drop table if exists senders; create table senders(id text);"
    )
  end

  def test_if_not_exists_is_not_a_collision
    assert_empty collisions("create table t(id text);", "create table if not exists t(id text);")
    assert_empty collisions("create schema issues;", "create schema if not exists issues;")
  end

  # Ten scripts drop a whole feature's tables in one statement. Reading only the
  # first name leaves the rest recorded as live forever.
  def test_a_comma_separated_drop_clears_every_name
    assert_empty collisions(
      "create table sms.conversations(id text); create table sms.messages(id text);",
      "drop table if exists sms.conversations, sms.messages; " \
      "create table sms.conversations(id text); create table sms.messages(id text);"
    )
  end

  def test_a_drop_may_end_in_cascade
    assert_empty collisions(
      "create table worker.invocations(id text);",
      "drop table if exists worker.invocations cascade; create table worker.invocations(id text);"
    )
  end

  # Not an optional refinement: without it every index in every re-runnable
  # script reads as a collision — 133 of them across platform-postgresql.
  def test_dropping_a_table_drops_the_indexes_on_it
    assert_empty collisions(
      "create table t(id text); create index t_id_idx on t(id);",
      "drop table if exists t; create table t(id text); create index t_id_idx on t(id);"
    )
  end

  def test_an_index_recreated_without_its_table_being_dropped_is_a_collision
    found = collisions(
      "create table t(id text); create index t_id_idx on t(id);",
      "create index t_id_idx on t(id);"
    )
    assert_equal ["index"], found.map(&:kind)
    assert_equal ["public.t_id_idx"], found.map(&:name)
  end

  def test_dropping_a_schema_clears_what_was_in_it
    assert_empty collisions(
      "create schema sms; set search_path to sms; create table messages(id text); " \
      "create index messages_id_idx on messages(id);",
      "drop schema sms cascade; create schema sms; set search_path to sms; " \
      "create table messages(id text); create index messages_id_idx on messages(id);"
    )
  end

  # ---- renames and moves ----------------------------------------------------

  # 20260702-120000.sql renames user_last_sessions out of the way and then
  # creates a NEW table under the freed name.
  def test_a_rename_frees_the_old_name
    assert_empty collisions(
      "create table user_last_sessions(id text);",
      "alter table user_last_sessions rename to user_last_logins; create table user_last_sessions(id text);"
    )
  end

  def test_a_rename_carries_the_indexes_with_the_table
    assert_empty collisions(
      "create table t(id text); create index t_id_idx on t(id);",
      "alter table t rename to u;",
      "drop table if exists u; create table t(id text); create index t_id_idx on t(id);"
    )
  end

  # 27 statements move a table into hoa / playbook / clubaid this way.
  def test_set_schema_moves_the_table
    assert_empty collisions(
      "create table properties(id text);",
      "alter table properties set schema hoa; create table properties(id text);"
    )
    assert_equal 1, collisions(
      "create table properties(id text);",
      "alter table properties set schema hoa;",
      "create table hoa.properties(id text);"
    ).length
  end

  # `alter schema privatedinkers rename to rallyd` carried 20 tables and their
  # indexes; before this they stayed recorded under a schema that no longer
  # exists and nothing under rallyd was tracked at all.
  def test_renaming_a_schema_carries_its_contents
    assert_empty collisions(
      "create schema privatedinkers; set search_path to privatedinkers; create table games(id text); " \
      "create index games_id_idx on games(id);",
      "alter schema privatedinkers rename to rallyd;",
      "drop table if exists rallyd.games; create table rallyd.games(id text); " \
      "create index rallyd.games_id_idx on rallyd.games(id);"
    )
    assert_equal ["table"], collisions(
      "create schema privatedinkers; set search_path to privatedinkers; create table games(id text);",
      "alter schema privatedinkers rename to rallyd;",
      "create table rallyd.games(id text);"
    ).map(&:kind)
  end

  # ---- what is deliberately not read as a create ----------------------------

  # A temp table belongs to the session that made it, so two scripts creating
  # `_decouple` are not in conflict. Eight scripts do this.
  def test_temp_tables_are_ignored
    assert_empty collisions(
      "create temp table _decouple as select 1;",
      "create temporary table _decouple as select 1;"
    )
  end

  # `create index on t(...)` leaves Postgres to name it, so there is no name to
  # collide on.
  def test_an_unnamed_index_is_ignored
    assert_empty collisions("create index on t(id);", "create index on t(id);")
    assert_empty collisions("create unique index on t(id);", "create unique index on t(id);")
  end

  # Every generated migration writes its intent above the DDL, and half of those
  # comments quote the SQL they are about.
  def test_a_create_only_mentioned_in_a_comment_is_ignored
    assert_empty collisions(
      "create table t(id text);",
      "-- supersedes the create table t in the previous script\n/* create table t(id text); */\nalter table t add column c text;"
    )
  end

  # Erring toward silence: a second `add constraint` does halt sem, but
  # `drop table x cascade` silently drops other tables' inbound foreign keys, and
  # modelling that needs the reference graph. Two of platform-postgresql's
  # scripts read as collisions without it, and a false collision blocks a
  # release and every session's database.
  def test_constraints_are_not_tracked
    assert_empty collisions(
      "alter table t add constraint t_c_fk foreign key(c) references u;",
      "alter table t add constraint t_c_fk foreign key(c) references u;"
    )
  end

  # Overloading makes a function's identity its signature, and the house style is
  # `create or replace` anyway.
  def test_functions_are_not_tracked
    assert_empty collisions(
      "create function f() returns int as $$ select 1 $$ language sql;",
      "create function f() returns int as $$ select 2 $$ language sql;"
    )
  end

  def test_or_replace_is_not_a_collision
    assert_empty collisions("create view v as select 1;", "create or replace view v as select 2;")
  end

  # ---- ordering, reporting --------------------------------------------------

  # sem-apply orders by filename, not by commit date — which is the whole reason
  # 20260805-213151.sql won the ISS-592 race and 213210 was the one that died.
  def test_scripts_replay_in_filename_order
    found = with_scripts(
      "20260805-213210.sql" => "set search_path to issues; create table senders(id text);",
      "20260805-213151.sql" => "set search_path to issues; create table senders(id text);"
    ) { |dir| SchemaCollisions.scan(dir) }

    assert_equal "20260805-213151.sql", found.first.first_script
    assert_equal "20260805-213210.sql", found.first.script
  end

  def test_a_clean_repo_scans_empty
    assert_empty with_scripts("20260801-a.sql" => "create table t(id text);") { |dir| SchemaCollisions.scan(dir) }
  end

  def test_scripts_involved_names_both_sides_once
    found = collisions(INTAKE_A, INTAKE_B)
    assert_equal ["20260800-000000.sql", "20260801-000000.sql"], SchemaCollisions.scripts_involved(found)
  end

  def test_the_failure_message_names_the_scripts_the_object_and_the_fix
    out = SchemaCollisions.failure_message("/tmp/platform-postgresql", collisions(INTAKE_A, INTAKE_B))
    assert_includes out, "/tmp/platform-postgresql"
    assert_includes out, "20260800-000000.sql"
    assert_includes out, "20260801-000000.sql"
    assert_includes out, "issues.issue_intake_senders"
    assert_includes out, "drop table if exists"
    assert_includes out, "dev schema lint"
  end

  def test_describe_groups_by_the_script_that_collided
    out = SchemaCollisions.describe(collisions(INTAKE_A, INTAKE_B))
    assert_equal 1, out.scan("20260801-000000.sql").length, "the offending script is named once, not per object"
    assert_includes out, "issues.issue_intake_senders_tenant_id_status_idx"
  end
end
