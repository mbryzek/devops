#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_helper'
require_relative '../lib/schema_compat'

# Covers the check that stops a rename shipping in the same release as the code
# that needs it (ISS-864).
#
# INCIDENT is the regression bar: it is 20260807-171639.sql's step 6 verbatim,
# the statement that answered 500 on every read and write of issues.issues on
# 2026-08-07. If it ever stops being a finding, the check is not doing the one
# thing it exists to do. ADDITIVE is the other half of the bar — a purely
# expanding script has to stay silent, because a check that flags ordinary
# migrations is one that gets a blanket opt-out pasted into every script.
class TestSchemaCompat < Minitest::Test
  INCIDENT = <<~SQL
    -- 6. issues.producer_key -> issues.producer_id, same mapping and the same reasoning.
    alter table issues.issues rename column producer_key to producer_id;

    alter table issues.issues rename constraint issues_producer_key_check to issues_producer_id_check;
    alter index issues.issues_tenant_id_producer_key_producer_key_notnull_idx
      rename to issues_tenant_id_producer_id_producer_id_notnull_idx;
  SQL

  ADDITIVE = <<~SQL
    create table playbook.widgets (id text primary key, name text not null);
    alter table playbook.clubs add column widget_id text;
    create index widgets_name_idx on playbook.widgets(name);
    drop index if exists widgets_old_idx;
  SQL

  def findings(sql, unreleased = SchemaCompat::UnreleasedObjects.empty)
    SchemaCompat.findings("scripts/t.sql", sql, unreleased)
  end

  def objects(sql, unreleased = SchemaCompat::UnreleasedObjects.empty)
    findings(sql, unreleased).map(&:object)
  end

  # --- what counts ------------------------------------------------------------

  def test_the_incident_rename_is_a_finding
    assert_equal ["issues.producer_key"], objects(INCIDENT)
  end

  def test_a_purely_additive_script_is_silent
    assert_empty findings(ADDITIVE)
  end

  def test_renaming_a_table_is_a_finding
    assert_equal ["insight_rules"], objects("alter table insight_rules rename to playbook_rules;")
  end

  def test_renaming_a_view_is_a_finding
    assert_equal ["club_summaries"], objects("alter view playbook.club_summaries rename to club_rollups;")
  end

  def test_changing_a_column_type_is_a_finding
    assert_equal ["responses.data"],
                 objects(%(alter table intuit.responses alter column "data" type jsonb using "data"::jsonb;))
  end

  def test_one_statement_retyping_several_columns_reports_each
    assert_equal ["invoices.custom_fields", "invoices.lines"],
                 objects("alter table intuit.invoices alter column custom_fields type jsonb, " \
                         "alter column lines type jsonb;")
  end

  def test_the_column_keyword_is_optional
    assert_equal ["clubs.legacy_name"], objects("alter table clubs rename legacy_name to name;")
  end

  # --- what is deliberately exempt -------------------------------------------

  # No query names an index, a trigger or a constraint, so renaming one is
  # invisible to the application — and the house style pairs those renames with
  # the column rename they belong to, so flagging them would flag every
  # well-written script twice.
  def test_index_trigger_and_constraint_renames_are_exempt
    assert_empty findings("alter index issues.a_idx rename to b_idx;")
    assert_empty findings("alter trigger t_updated_at on t rename to u_updated_at;")
    assert_empty findings("alter table t rename constraint t_check to u_check;")
  end

  # A `format('alter table %I.%I rename to %I')` inside a function body names a
  # placeholder. 20260801-161500.sql does exactly this for journal partitions.
  def test_dynamic_sql_inside_a_function_body_is_not_a_finding
    sql = <<~SQL
      create or replace function rotate() returns void as $$
      begin
        execute format('alter table %I.%I rename to %I', s, p, p || '_old');
      end;
      $$ language plpgsql;
    SQL
    assert_empty findings(sql)
  end

  # The rename is in prose above the DDL in every generated migration.
  def test_a_rename_mentioned_only_in_a_comment_is_not_a_finding
    assert_empty findings("-- this used to rename column producer_key to producer_id\nselect 1;")
  end

  # --- objects the same unreleased batch created ------------------------------

  def test_renaming_a_column_of_a_table_this_batch_created_is_free
    unreleased = SchemaCompat::UnreleasedObjects.from_bodies(["create table playbook.widgets (id text);"])
    assert_empty findings("alter table widgets rename column id to widget_id;", unreleased)
  end

  def test_renaming_a_table_this_batch_created_is_free
    unreleased = SchemaCompat::UnreleasedObjects.from_bodies(["create table widgets (id text);"])
    assert_empty findings("alter table widgets rename to gadgets;", unreleased)
  end

  def test_renaming_a_column_this_batch_added_is_free
    unreleased = SchemaCompat::UnreleasedObjects.from_bodies(["alter table clubs add column widget_id text;"])
    assert_empty findings("alter table clubs rename column widget_id to gadget_id;", unreleased)
  end

  # The narrow reading matters: a column added to clubs must not exempt a rename
  # of the same-named column on a DIFFERENT, released table.
  def test_a_column_added_to_one_table_does_not_exempt_another_tables_column
    unreleased = SchemaCompat::UnreleasedObjects.from_bodies(["alter table clubs add column widget_id text;"])
    assert_equal ["members.widget_id"],
                 objects("alter table members rename column widget_id to gadget_id;", unreleased)
  end

  # --- the opt-out ------------------------------------------------------------

  def test_a_directive_naming_the_object_suppresses_it
    sql = "-- schema-compat: no-live-reader issues.producer_key -- nothing has ever selected it\n" + INCIDENT
    assert_empty findings(sql)
  end

  # A file-level "I know what I am doing" is exactly what would carry over to
  # the next rename somebody adds to the same script.
  def test_a_directive_does_not_cover_an_object_it_does_not_name
    sql = "-- schema-compat: no-live-reader issues.producer_key -- nothing has ever selected it\n" \
          "alter table issues.issues rename column producer_key to producer_id;\n" \
          "alter table agent_producers rename column key to id;\n"
    assert_equal ["agent_producers.key"], objects(sql)
  end

  # The reason is the point. Without one, the directive does not parse, and the
  # author gets the failure message that shows them the form to write.
  def test_a_directive_without_a_reason_does_not_suppress
    sql = "-- schema-compat: no-live-reader issues.producer_key\n" + INCIDENT
    assert_equal ["issues.producer_key"], objects(sql)
  end

  # --- script selection -------------------------------------------------------

  def with_repo
    Dir.mktmpdir do |dir|
      run = ->(*cmd) { system(*cmd, chdir: dir, out: File::NULL, err: File::NULL) || raise("failed: #{cmd.join(' ')}") }
      run.call("git", "init", "-q", "-b", "main")
      run.call("git", "config", "user.email", "test@example.com")
      run.call("git", "config", "user.name", "test")
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      yield dir, run
    end
  end

  def commit_script(dir, run, name, sql, tag: nil)
    File.write(File.join(dir, "scripts", name), sql)
    run.call("git", "add", "-A")
    run.call("git", "commit", "-q", "-m", name)
    run.call("git", "tag", tag) if tag
  end

  def test_unreleased_scripts_are_the_ones_after_the_latest_tag
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-a.sql", ADDITIVE, tag: "0.0.1")
      commit_script(dir, run, "20260807-b.sql", INCIDENT)

      assert_equal ["scripts/20260807-b.sql"], SchemaCompat.unreleased_scripts(dir)
      assert_equal ["issues.producer_key"],
                   SchemaCompat.scan_scripts(dir, SchemaCompat.unreleased_scripts(dir)).map(&:object)
    end
  end

  # A released rename cannot be unshipped, so reporting one is advice nobody can
  # take — and reading the whole history would report 57 of platform-postgresql's
  # 917 scripts, which is a check nobody keeps.
  def test_a_released_rename_is_not_reported
    with_repo do |dir, run|
      commit_script(dir, run, "20260807-b.sql", INCIDENT, tag: "0.0.1")
      assert_empty SchemaCompat.unreleased_scripts(dir)
    end
  end

  # Nothing has been released, so nothing can have a live reader.
  def test_a_repo_with_no_tags_has_nothing_to_check
    with_repo do |dir, run|
      commit_script(dir, run, "20260807-b.sql", INCIDENT)
      assert_empty SchemaCompat.unreleased_scripts(dir)
    end
  end

  # The working tree, not HEAD: a session lints the migration it has just
  # written and usually has not committed.
  def test_an_uncommitted_script_is_unreleased
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-a.sql", ADDITIVE, tag: "0.0.1")
      File.write(File.join(dir, "scripts", "20260807-b.sql"), INCIDENT)
      assert_equal ["scripts/20260807-b.sql"], SchemaCompat.unreleased_scripts(dir)
    end
  end

  # claude-db asks the narrower question — what did THIS BRANCH add — so a
  # session is never blocked by somebody else's merged-but-unreleased script.
  def test_added_scripts_are_only_the_ones_this_branch_adds
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-a.sql", ADDITIVE)
      run.call("git", "branch", "-f", "origin/main", "main")
      commit_script(dir, run, "20260807-b.sql", INCIDENT)

      assert_equal ["scripts/20260807-b.sql"], SchemaCompat.added_scripts(dir, "origin/main")
      assert_empty SchemaCompat.added_scripts(dir, "origin/main").reject { |s| s.end_with?("b.sql") }
    end
  end

  # An unresolvable base leaves no branch to compare, and treating every script
  # as added would report the whole history at a call site that must never be
  # the reason a session cannot get a database.
  def test_added_scripts_is_empty_when_the_base_ref_does_not_resolve
    with_repo do |dir, run|
      commit_script(dir, run, "20260807-b.sql", INCIDENT)
      assert_empty SchemaCompat.added_scripts(dir, "origin/main")
    end
  end

  # --- operator-facing text ---------------------------------------------------

  def test_failure_message_names_the_object_and_the_directive_to_write
    out = SchemaCompat.failure_message("/tmp/repo", findings(INCIDENT))
    assert_match(/issues\.producer_key/, out)
    assert_match(/-- schema-compat: no-live-reader issues\.producer_key -- /, out)
    assert_match(/three releases/, out)
  end

  def test_release_warning_names_the_tag_and_the_statements
    out = SchemaCompat.release_warning("0.5.66", findings(INCIDENT))
    assert_match(/0\.5\.66/, out)
    assert_match(/alter table issues\.issues rename column producer_key to producer_id/, out)
    assert_match(/NO ORDERING/, out)
  end
end
