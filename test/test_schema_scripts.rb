#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_helper'
require_relative '../lib/schema_scripts'

# Covers the expanding/contracting classification that decides whether a schema
# release may be applied before its app or has to wait until after it.
#
# The two shapes at the top are the migrations behind the 2026-08-03 and
# 2026-08-04 production incidents. They are the regression bar: if either one
# ever classifies as expanding again, `dev deploy all` puts it back in Phase 1
# and the live code starts answering `does not exist` for the length of a
# rollout.
class TestSchemaScripts < Minitest::Test
  DROP_COLUMN = <<~SQL
    -- ISS-226: consolidate the revenue business line and GL account into one dimension
    alter table playbook.revenue_entries drop column business_line_id;
  SQL

  DROP_TABLE = <<~SQL
    -- ISS-287: Remove membership label normalization end to end
    drop table playbook.membership_categories;
  SQL

  def contracting(sql)
    SchemaScripts.contracting_statements(sql)
  end

  def test_dropping_a_column_is_contracting
    assert_equal ["alter table playbook.revenue_entries drop column business_line_id"], contracting(DROP_COLUMN)
  end

  def test_dropping_a_table_is_contracting
    assert_equal ["drop table playbook.membership_categories"], contracting(DROP_TABLE)
  end

  def test_bare_column_drop_without_the_column_keyword_is_contracting
    assert_equal 1, contracting("alter table playbook.clubs drop legacy_name;").length
  end

  # The lookahead that recognizes the bare form by what it is NOT matched a
  # PREFIX, so every one of these ordinary column names read as expanding and got
  # applied BEFORE the app that still selected it -- ISS-317's outage, from the
  # classifier written to prevent it. `legacy_name` above shares no prefix with a
  # keyword, which is why it passed throughout.
  def test_a_bare_column_drop_is_contracting_when_the_column_name_begins_with_a_keyword
    %w[
      type_id trigger_source default_locale not_before indexed_at
      owned_by_id constraint_type policy_id table_name schema_version
      view_count function_name sequence_number column_name
    ].each do |column|
      sql = "alter table playbook.clubs drop #{column};"
      assert_equal [sql.chomp(";")], contracting(sql), "#{column} must be read as contracting"
    end
  end

  # The other side of the same boundary: these really are the keyword, and the
  # ones in SAFE_DROPS remove no name a query mentions, so they must stay
  # expanding. A `\b` that over-matched would sweep them in and defer every
  # additive release that reindexes.
  def test_the_safe_drop_keywords_themselves_are_still_expanding
    assert_empty contracting("alter table playbook.clubs drop constraint clubs_pkey;")
    assert_empty contracting("alter table playbook.clubs drop index clubs_name_idx;")
    assert_empty contracting("alter table playbook.clubs alter column nick drop not null;")
    assert_empty contracting("alter table playbook.clubs alter column nick drop default;")
  end

  def test_renames_are_contracting
    assert_equal 1, contracting("alter table playbook.clubs rename column nick to nickname;").length
    assert_equal 1, contracting("alter table playbook.clubs rename to organizations;").length
  end

  def test_drop_of_every_named_object_kind_is_contracting
    %w[
      drop\ schema\ playbook
      drop\ view\ playbook.club_totals
      drop\ materialized\ view\ playbook.club_totals
      drop\ sequence\ playbook.club_seq
      drop\ type\ playbook.club_status
      drop\ function\ playbook.club_label(text)
    ].each do |statement|
      assert_equal 1, contracting("#{statement};").length, "expected #{statement.inspect} to be contracting"
    end
  end

  # The other direction is the one that costs something: a false "contracting"
  # defers a migration the NEW code needs until after its rollout. Every drop
  # that only changes shape - never a name a query mentions - stays expanding.
  def test_ordinary_additive_scripts_are_expanding
    assert_empty contracting(<<~SQL)
      create table playbook.watermarks (id text primary key, club_id text not null);
      alter table playbook.revenue_entries add column member_external_id text;
      create index on playbook.revenue_entries(club_id);
      alter table playbook.revenue_entries alter column amount drop default;
      alter table playbook.revenue_entries alter column amount drop not null;
      alter table playbook.revenue_entries drop constraint revenue_entries_pkey;
      drop index playbook.revenue_entries_club_id_idx;
      drop trigger journal_trigger on playbook.revenue_entries;
    SQL
  end

  # `drop table if exists x; create table x (...)` is how a large share of the
  # generated migrations open. Reading the guard as a contraction deferred 40%
  # of all purely additive releases until after their app when this was measured
  # against the 872 scripts in platform-postgresql.
  def test_a_drop_that_the_same_script_recreates_is_expanding
    assert_empty contracting(<<~SQL)
      drop table if exists playbook.executions;
      create table playbook.executions (id text primary key);
    SQL
  end

  def test_the_recreate_may_qualify_the_name_differently_than_the_drop
    assert_empty contracting(<<~SQL)
      drop table if exists executions;
      create table playbook.executions (id text primary key);
    SQL
  end

  def test_a_drop_of_something_else_in_a_creating_script_is_still_contracting
    assert_equal ["drop table playbook.membership_categories"], contracting(<<~SQL)
      create table playbook.executions (id text primary key);
      drop table playbook.membership_categories;
    SQL
  end

  # No query names an index, so renaming one cannot produce `does not exist`.
  # It rides along with the column rename it belongs to (20260803-142920.sql).
  def test_renaming_an_index_is_expanding
    assert_empty contracting("alter index revenue_entries_business_line_id_idx rename to revenue_entries_revenue_category_id_idx;")
  end

  # A non-UTF-8 default external encoding is what a release run from launchd or
  # over ssh gets, and migration comments are full of em dashes. Before this was
  # scrubbed, the classifier raised `invalid byte sequence` mid-deploy.
  def test_classifies_a_script_read_under_a_us_ascii_locale
    sql = "-- drops the — legacy — column\nalter table t drop column c;".dup
    assert_equal ["alter table t drop column c"], contracting(sql.force_encoding(Encoding::US_ASCII))
  end

  def test_a_drop_only_mentioned_in_a_comment_is_expanding
    assert_empty contracting(<<~SQL)
      -- supersedes the drop table playbook.membership_categories in 20260803.sql
      /* we will drop column business_line_id in a later release */
      alter table playbook.revenue_entries add column vendor text;
    SQL
  end

  def test_a_mixed_script_reports_only_the_destructive_statements
    statements = contracting(<<~SQL)
      alter table playbook.revenue_entries add column vendor text;
      create index on playbook.revenue_entries(vendor);
      alter table playbook.revenue_entries drop column business_line_id;
    SQL
    assert_equal ["alter table playbook.revenue_entries drop column business_line_id"], statements
  end

  def test_statements_are_reported_verbatim_with_whitespace_collapsed
    assert_equal ["drop table\nplaybook.membership_categories".gsub(/\s+/, " ")],
                 contracting("drop table\n  playbook.membership_categories;")
  end

  # --- git-backed helpers ----------------------------------------------------

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

  def test_contracting_reads_only_scripts_added_in_the_range
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-add.sql", "alter table t add column c text;", tag: "0.0.1")
      commit_script(dir, run, "20260803-drop.sql", DROP_COLUMN, tag: "0.0.2")

      assert_empty SchemaScripts.contracting(dir, "0.0.1", "0.0.1")
      assert_equal ["scripts/20260803-drop.sql"], SchemaScripts.contracting(dir, "0.0.1", "0.0.2").keys
    end
  end

  def test_contracting_is_empty_for_a_purely_additive_release
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-a.sql", "create table t (id text);", tag: "0.0.1")
      commit_script(dir, run, "20260802-b.sql", "alter table t add column c text;", tag: "0.0.2")
      assert_empty SchemaScripts.contracting(dir, "0.0.1", "0.0.2")
    end
  end

  # An edit to an already-released script is not something sem-apply will run
  # again - it keys on filename - so it must not turn the release contracting.
  def test_editing_an_already_added_script_does_not_make_the_release_contracting
    with_repo do |dir, run|
      commit_script(dir, run, "20260801-a.sql", "create table t (id text);", tag: "0.0.1")
      commit_script(dir, run, "20260801-a.sql", DROP_TABLE, tag: "0.0.2")
      assert_empty SchemaScripts.contracting(dir, "0.0.1", "0.0.2")
    end
  end

  def test_previous_tag_is_version_sorted
    with_repo do |dir, run|
      commit_script(dir, run, "a.sql", "create table t (id text);", tag: "0.0.9")
      commit_script(dir, run, "b.sql", "create table u (id text);", tag: "0.0.10")
      assert_equal "0.0.9", SchemaScripts.previous_tag(dir, "0.0.10")
      assert_nil SchemaScripts.previous_tag(dir, "0.0.9")
      assert_nil SchemaScripts.previous_tag(dir, "9.9.9")
    end
  end

  def test_contracting_warning_names_the_tag_the_statement_and_the_ordering
    out = SchemaScripts.contracting_warning(
      "0.2.7", "scripts/20260804-drop.sql" => ["drop table playbook.membership_categories"]
    )
    assert_includes out, "0.2.7 is a CONTRACTING release"
    assert_includes out, "drop table playbook.membership_categories"
    assert_includes out, "20260804-drop.sql"
    assert_includes out, "dev deploy all"
  end

  def test_describe_names_the_script_and_the_statement
    out = SchemaScripts.describe("scripts/20260803-drop.sql" => ["drop table playbook.membership_categories"])
    assert_includes out, "20260803-drop.sql"
    assert_includes out, "drop table playbook.membership_categories"
    refute_includes out, "scripts/scripts"
  end
end
