#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# Naming is the whole contract between an app and the session-DB tooling: the
# container `claude-db` looks for, the template it clones, the databases `gc`
# is willing to drop. Every one of those is DERIVED from the database name, and
# that derivation is what keeps platform's existing containers and session
# databases valid across the generalisation — platform must still produce
# exactly "platformdb-claude-<tag>", "platformdb_template", "platformdb_sess_*".
# A change here is a flag day for every running session, so it is pinned.
class TestDbApps < Minitest::Test
  include DevTestSupport

  def platform
    DbApp.new(:name => "platform", :database => "platformdb", :role => "api",
              :repo_dir => "/tmp/platform-postgresql")
  end

  def acumen
    DbApp.new(:name => "acumen", :database => "acumendb", :role => "api",
              :repo_dir => "/tmp/acumen-postgresql")
  end

  # ── names that must not move ──────────────────────────────────────────────

  def test_platform_naming_is_unchanged_by_generalisation
    app = platform
    assert_equal "platformdb", app.image_name
    assert_equal "registry.digitalocean.com/bryzek/platformdb:0.5.22", app.image_ref("0.5.22")
    assert_equal "platformdb-claude", app.container_prefix
    assert_equal "platformdb-claude-0.5.22", app.container_name("0.5.22")
    assert_equal "platformdb_template", app.template_db
    assert_equal "platformdb_sess_", app.sess_prefix
  end

  def test_acumen_naming_derives_from_its_database
    app = acumen
    assert_equal "registry.digitalocean.com/bryzek/acumendb:0.1.45", app.image_ref("0.1.45")
    assert_equal "acumendb-claude-0.1.45", app.container_name("0.1.45")
    assert_equal "acumendb_template", app.template_db
    assert_equal "acumendb_sess_", app.sess_prefix
  end

  # ── container ownership ───────────────────────────────────────────────────

  def test_container_schema_tag_round_trips
    assert_equal "0.5.22", platform.container_schema_tag(platform.container_name("0.5.22"))
  end

  # The pre-split container carries no tag. It may still hold other sessions'
  # databases, so it has to be recognisable rather than mistaken for a tagged one.
  def test_legacy_container_has_no_schema_tag
    assert_nil platform.container_schema_tag(platform.legacy_container)
    assert platform.owns_container?(platform.legacy_container)
  end

  def test_unrelated_container_is_not_owned
    refute platform.owns_container?("some-other-postgres")
    assert_nil platform.container_schema_tag("some-other-postgres")
  end

  # `docker ps --filter name=` is a substring match, which is why ownership is
  # re-checked in Ruby. Neither app may ever adopt the other's container: `gc`
  # removes containers it believes are empty, and it lists databases by the
  # app's own prefix — so an app that adopted a foreign container would see no
  # databases in it and delete another app's sessions.
  def test_apps_do_not_adopt_each_others_containers
    refute platform.owns_container?(acumen.container_name("0.1.45"))
    refute acumen.owns_container?(platform.container_name("0.5.22"))
    refute acumen.owns_container?(platform.legacy_container)
  end

  def test_session_db_ownership_is_per_app
    assert platform.owns_session_db?("platformdb_sess_foo")
    refute platform.owns_session_db?("acumendb_sess_foo")
  end

  # ── session database names ────────────────────────────────────────────────

  def test_session_db_name_sanitizes_a_feature_name
    assert_equal "platformdb_sess_cr_login_ladder", platform.session_db_name("cr-login-ladder")
    assert_equal "acumendb_sess_cr_login_ladder", acumen.session_db_name("cr-login-ladder")
  end

  # Truncation has to account for the app's own prefix — a shorter prefix means
  # more room, and both must stay inside the identifier limit or CREATE DATABASE
  # silently truncates and two sessions collide.
  def test_session_db_name_fits_the_postgres_identifier_limit
    [platform, acumen].each do |app|
      assert_operator app.session_db_name("x" * 200).length, :<=, DbImages::MAX_IDENTIFIER_LENGTH
      assert app.session_db_name("x" * 200).start_with?(app.sess_prefix)
    end
  end

  # ── app resolution ────────────────────────────────────────────────────────

  def test_base_name_accepts_either_form
    assert_equal "acumen", DbApp.base_name("acumen")
    assert_equal "acumen", DbApp.base_name("acumen-postgresql")
  end

  def test_default_repo_dir
    assert_equal File.expand_path("~/code/acumen-postgresql"), DbApp.default_repo_dir("acumen")
  end

  def test_for_container_picks_the_owning_app
    apps = [platform, acumen]
    assert_equal "acumen", DbApp.for_container("acumendb-claude-0.1.45", :apps => apps).name
    assert_equal "platform", DbApp.for_container("platformdb-claude-0.5.22", :apps => apps).name
    assert_nil DbApp.for_container("unrelated", :apps => apps)
  end

  # ── artifacts ─────────────────────────────────────────────────────────────

  # journal-settings is optional (platform has a journal schema, acumen does
  # not) and its absence is expressed by the file not existing — no per-app
  # flag anywhere in the tooling.
  def test_artifact_is_nil_when_absent
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "docker"))
      File.write(File.join(dir, "docker", "seed.sql"), "-- seed\n")
      app = DbApp.new(:name => "x", :database => "xdb", :role => "api", :repo_dir => dir)
      assert_equal File.join(dir, "docker", "seed.sql"), app.artifact(:seed)
      assert_nil app.artifact(:journal)
    end
  end

  def test_baseline_tag_is_read_from_the_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "docker"))
      File.write(File.join(dir, "docker", "baseline-tag"), "0.1.45\n")
      app = DbApp.new(:name => "x", :database => "xdb", :role => "api", :repo_dir => dir)
      assert_equal "0.1.45", app.baseline_tag
    end
  end

  def test_baseline_tag_missing_exits_with_instructions
    Dir.mktmpdir do |dir|
      app = DbApp.new(:name => "x", :database => "xdb", :role => "api", :repo_dir => dir)
      stderr, status = capture_stderr_and_exit { app.baseline_tag }
      assert_equal 1, status
      assert_match(/db-image baseline --app x/, stderr)
    end
  end
end
