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

  # ── per-subproject test databases ─────────────────────────────────────────
  #
  # A build may clone its session database once per subproject so their test
  # suites can run concurrently (platform does; see ISS-813). Those clones are
  # the same session's state and `end` reclaims them with it.

  def test_lane_owner_reads_the_session_database_out_of_a_clone
    assert_equal "platformdb_sess_i813", platform.lane_owner("platformdb_sess_i813__core")
  end

  def test_a_session_database_is_not_a_clone_of_anything
    assert_nil platform.lane_owner("platformdb_sess_i813")
  end

  def test_another_apps_database_is_never_ours
    assert_nil platform.lane_owner("acumendb_sess_i813__core")
  end

  # THE POINT OF THE DOUBLE UNDERSCORE, and the reason a single one would be a
  # data-loss bug rather than a style choice. `sanitize_session_id` collapses
  # runs of underscores, so no session database name can contain `__` — while a
  # single underscore is ambiguous exactly where the agent executor puts it: an
  # epic and its children get workspaces `i682` and `i682_c03`, so session
  # `i682_c03`'s whole database also reads as session `i682`'s `c03` clone.
  # Reclaiming session `i682` by single-underscore prefix would drop it.
  def test_a_sibling_sessions_database_is_not_mistaken_for_a_clone
    sibling = platform.session_db_name("i682_c03")

    assert_equal "platformdb_sess_i682_c03", sibling
    assert_nil platform.lane_owner(sibling)
    refute_equal platform.session_db_name("i682"), platform.lane_owner(sibling)
  end

  def test_a_sanitized_session_id_can_never_contain_the_separator
    ["i682--c03", "i682__c03", "a - b _ c"].each do |sid|
      refute_includes platform.session_db_name(sid), DbApp::LANE_SEPARATOR, "sid=#{sid}"
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

  # ── resolving an app from where the command was run ───────────────────────

  # A schema repo is recognised by what it contains, not by living under ~/code:
  # the same inference has to work in a feature clone under ~/code/ai.
  def schema_repo(parent, name)
    dir = File.join(parent, name)
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    dir
  end

  def test_cwd_repo_dir_is_the_schema_repo_the_command_was_run_from
    Dir.mktmpdir do |parent|
      assert_equal schema_repo(parent, "platform-postgresql"),
                   DbApp.cwd_repo_dir(schema_repo(parent, "platform-postgresql"))
      # Released checkouts carry a version suffix.
      assert_equal schema_repo(parent, "acumen-postgresql-15.1.0"),
                   DbApp.cwd_repo_dir(schema_repo(parent, "acumen-postgresql-15.1.0"))
    end
  end

  # The app repo names the app but holds no schema, and an empty directory that
  # merely looks like a schema repo would send pg_dump at nothing.
  def test_cwd_repo_dir_is_nil_outside_a_schema_repo
    Dir.mktmpdir do |parent|
      FileUtils.mkdir_p(File.join(parent, "platform"))
      assert_nil DbApp.cwd_repo_dir(File.join(parent, "platform"))
      FileUtils.mkdir_p(File.join(parent, "platform-postgresql"))
      assert_nil DbApp.cwd_repo_dir(File.join(parent, "platform-postgresql"))
    end
  end

  # Stubbing the cwd -> name step keeps these tests off this box's ~/code and
  # env/apps; the mapping itself is Args.default_app, which every other command
  # already relies on.
  def with_cwd_name(name)
    stubs = {
      :cwd_name => lambda { |_dir = nil| name },
      # Config lookup, which needs this box's env/apps and ~/code checkouts.
      :load => lambda { |n, repo_dir: nil, repo_source: nil|
        DbApp.new(:name => n, :database => "#{n}db", :role => "api",
                  :repo_dir => repo_dir || "/code/#{n}-postgresql",
                  :repo_source => repo_source || (repo_dir ? :explicit : :default))
      }
    }
    originals = stubs.keys.map { |m| [m, DbApp.method(m)] }
    stubs.each { |m, impl| DbApp.define_singleton_method(m, impl) }
    yield
  ensure
    originals.each { |m, impl| DbApp.define_singleton_method(m, impl) }
  end

  def test_resolve_infers_the_app_and_its_checkout_from_the_directory
    Dir.mktmpdir do |parent|
      dir = schema_repo(parent, "platform-postgresql")
      with_cwd_name("platform") do
        app = DbApp.resolve(:dir => dir)
        assert_equal "platform", app.name
        assert_equal dir, app.repo_dir
      end
    end
  end

  # Standing in one app's schema repo must not point another app's build at it.
  def test_resolve_ignores_the_directory_when_app_names_a_different_app
    Dir.mktmpdir do |parent|
      dir = schema_repo(parent, "platform-postgresql")
      with_cwd_name("platform") do
        app = DbApp.resolve(:name => "acumen", :dir => dir)
        assert_equal "acumen", app.name
        assert_equal "/code/acumen-postgresql", app.repo_dir
      end
    end
  end

  def test_resolve_prefers_an_explicit_repo_dir
    Dir.mktmpdir do |parent|
      dir = schema_repo(parent, "platform-postgresql")
      with_cwd_name("platform") do
        assert_equal "/elsewhere", DbApp.resolve(:repo_dir => "/elsewhere", :dir => dir).repo_dir
      end
    end
  end

  # The case the drift work exists for: a session runs its suite from
  # ~/code/ai/<feature>/platform, whose sibling clone carries the branch's own
  # migration. Reaching past it to ~/code/platform-postgresql syncs the database
  # to main and silently omits that migration.
  def test_resolve_adopts_a_sibling_schema_clone
    Dir.mktmpdir do |feature|
      sibling = schema_repo(feature, "platform-postgresql")
      app_dir = File.join(feature, "platform")
      FileUtils.mkdir_p(app_dir)
      with_cwd_name("platform") do
        assert_equal sibling, DbApp.resolve(:name => "platform", :dir => app_dir).repo_dir
        # And from the feature directory itself, where the clone is a child.
        assert_equal sibling, DbApp.resolve(:name => "platform", :dir => feature).repo_dir
      end
    end
  end

  # A directory that merely shares a parent with the app is not a checkout: only
  # a real schema repo (scripts/ or a baseline tag) counts, so an empty
  # placeholder falls through to ~/code rather than sending sem-apply at nothing.
  def test_resolve_falls_back_when_no_sibling_clone_exists
    Dir.mktmpdir do |feature|
      app_dir = File.join(feature, "platform")
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(File.join(feature, "platform-postgresql"))
      with_cwd_name("platform") do
        assert_equal "/code/platform-postgresql",
                     DbApp.resolve(:name => "platform", :dir => app_dir).repo_dir
      end
    end
  end

  # ── where the checkout came from ──────────────────────────────────────────
  #
  # `claude-db` replaces the fallback checkout with a clone it keeps at
  # origin/main, and it may replace ONLY that one: the other three are a choice
  # the caller made and can hold a migration in progress that exists nowhere
  # else. Path alone cannot tell them apart — standing in
  # ~/code/platform-postgresql and falling back to it produce the same string —
  # so the provenance is recorded rather than inferred.
  def test_repo_source_records_which_rule_chose_the_checkout
    Dir.mktmpdir do |feature|
      sibling = schema_repo(feature, "platform-postgresql")
      app_dir = File.join(feature, "platform")
      FileUtils.mkdir_p(app_dir)
      with_cwd_name("platform") do
        assert_equal :cwd, DbApp.resolve(:dir => sibling).repo_source
        assert_equal :sibling, DbApp.resolve(:name => "platform", :dir => app_dir).repo_source
        assert_equal :explicit,
                     DbApp.resolve(:name => "platform", :repo_dir => "/elsewhere", :dir => app_dir).repo_source
      end
    end
  end

  # The one nobody chose, and the only one safe to swap out.
  def test_repo_source_is_default_when_nothing_pointed_anywhere
    Dir.mktmpdir do |dir|
      with_cwd_name(nil) do
        app = DbApp.resolve(:name => "platform", :dir => dir)
        assert_equal "/code/platform-postgresql", app.repo_dir
        assert_equal :default, app.repo_source
      end
    end
  end

  # An unrecognised source is not inert — `claude-db` gates the substitution on
  # `== :default`, so a typo would silently switch it off and bring the stale
  # checkout back.
  def test_an_unknown_repo_source_is_rejected
    assert_raises(ArgumentError) do
      DbApp.new(:name => "x", :database => "xdb", :role => "api",
                :repo_dir => "/tmp/x", :repo_source => :deafult)
    end
  end

  def test_with_repo_dir_keeps_the_app_and_moves_the_checkout
    moved = platform.with_repo_dir("/mirrors/platform-postgresql", :repo_source => :mirror)
    assert_equal "platformdb", moved.database
    assert_equal "/mirrors/platform-postgresql", moved.repo_dir
    assert_equal :mirror, moved.repo_source
    # And the original is untouched.
    assert_equal "/tmp/platform-postgresql", platform.repo_dir
  end

  # Nothing to infer is the one case where --app is genuinely required.
  def test_resolve_is_nil_when_the_directory_names_no_app
    Dir.mktmpdir do |dir|
      with_cwd_name(nil) do
        assert_nil DbApp.resolve(:dir => dir)
      end
    end
  end

  # ── schema drift ──────────────────────────────────────────────────────────
  #
  # The image tag is the latest RELEASED schema tag, so a session database is
  # normally behind main the moment it is cloned. What it is behind BY is the
  # difference between the checkout's scripts/ and the rows SEM recorded, and
  # everything `claude-db sync` does hangs off getting that set right.

  # Run a block with psql answering `responses`, keyed by a substring of the SQL.
  # Unmatched queries return [] — which is also what the real psql_query does on
  # error, and is exactly the case the guard below has to survive.
  def with_psql(responses)
    orig = DbImages.method(:psql_query)
    DbImages.define_singleton_method(:psql_query) do |_port, sql, **_kwargs|
      _key, value = responses.find { |k, _v| sql.include?(k) }
      value || []
    end
    yield
  ensure
    DbImages.define_singleton_method(:psql_query, orig)
  end

  def repo_with_scripts(names)
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    names.each { |n| File.write(File.join(dir, "scripts", n), "-- #{n}\n") }
    [DbApp.new(:name => "x", :database => "xdb", :role => "api", :repo_dir => dir), dir]
  end

  # Filenames are timestamps, so lexical order IS apply order — sem-apply runs
  # them in that order and a set that came back shuffled would reorder migrations.
  def test_repo_scripts_are_sorted_and_only_sql
    app, dir = repo_with_scripts(["20260803-190831.sql", "20260801-165150.sql", "README.md"])
    assert_equal ["20260801-165150.sql", "20260803-190831.sql"], app.repo_scripts
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_pending_scripts_is_what_the_checkout_has_and_the_database_lacks
    app, dir = repo_with_scripts(["20260801-165150.sql", "20260803-171500.sql", "20260803-190831.sql"])
    with_psql("SELECT filename" => ["20260801-165150.sql"]) do
      assert_equal ["20260803-171500.sql", "20260803-190831.sql"], app.pending_scripts(5555, "xdb_sess_a")
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_pending_scripts_is_empty_when_the_database_has_them_all
    app, dir = repo_with_scripts(["20260801-165150.sql", "20260803-171500.sql"])
    with_psql("SELECT filename" => ["20260803-171500.sql", "20260801-165150.sql"]) do
      assert_empty app.pending_scripts(5555, "xdb_sess_a")
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # THE guard. psql_query swallows errors and returns [], so a database whose
  # tracking table is unreadable looks identical to one with zero scripts
  # applied. Without this check the caller would replay the entire script history
  # against an already-full schema.
  def test_sem_tracking_is_false_when_the_table_is_absent_or_unreadable
    app, dir = repo_with_scripts([])
    with_psql({}) do
      refute app.sem_tracking?(5555, "xdb_sess_a")
    end
    with_psql("to_regclass" => ["f"]) do
      refute app.sem_tracking?(5555, "xdb_sess_a")
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_sem_tracking_is_true_when_the_table_is_there
    app, dir = repo_with_scripts([])
    with_psql("to_regclass" => ["t"]) do
      assert app.sem_tracking?(5555, "xdb_sess_a")
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # ── drift of the CHECKOUT against main ────────────────────────────────────
  #
  # The second staleness gap, and the one that survives a sync: syncing matches
  # the database to a checkout, so a checkout missing main's migrations leaves
  # the database missing them too — identical failures, one level up (ISS-545).
  #
  # Measured in scripts rather than commits on purpose. A checkout twenty
  # commits behind on README edits runs a perfectly good suite; one commit
  # behind on a migration does not, and only the script list can tell those
  # apart.

  # A real clone of a real origin: every property here is a git property.
  def with_clone_of_origin(origin_scripts)
    Dir.mktmpdir do |root|
      origin = File.join(root, "origin.git")
      seed   = File.join(root, "seed")
      system("git", "init", "--quiet", "--bare", "--initial-branch=main", origin,
             :out => File::NULL, :err => File::NULL)
      system("git", "clone", "--quiet", origin, seed, :out => File::NULL, :err => File::NULL)
      system("git", "config", "user.email", "test@example.com", :chdir => seed)
      system("git", "config", "user.name", "test", :chdir => seed)
      FileUtils.mkdir_p(File.join(seed, "scripts"))
      origin_scripts.each { |n| File.write(File.join(seed, "scripts", n), "select 1;\n") }
      system("git", "add", "-A", :chdir => seed, :out => File::NULL, :err => File::NULL)
      system("git", "commit", "--quiet", "-m", "scripts", :chdir => seed,
             :out => File::NULL, :err => File::NULL)
      system("git", "push", "--quiet", "origin", "main", :chdir => seed,
             :out => File::NULL, :err => File::NULL)

      checkout = File.join(root, "platform-postgresql")
      system("git", "clone", "--quiet", origin, checkout, :out => File::NULL, :err => File::NULL)
      yield DbApp.new(:name => "platform", :database => "platformdb", :role => "api",
                      :repo_dir => checkout)
    end
  end

  def test_missing_scripts_vs_origin_is_what_main_has_and_the_checkout_lacks
    with_clone_of_origin(["20260101000000.sql", "20260202000000.sql"]) do |app|
      assert_empty app.missing_scripts_vs_origin
      FileUtils.rm(File.join(app.repo_dir, "scripts", "20260202000000.sql"))
      assert_equal ["20260202000000.sql"], app.missing_scripts_vs_origin
    end
  end

  # One-directional: a script the checkout has and main does not is this
  # branch's own migration, which is the normal case and not drift.
  def test_a_branchs_own_migration_is_not_drift
    with_clone_of_origin(["20260101000000.sql"]) do |app|
      File.write(File.join(app.repo_dir, "scripts", "20260303000000.sql"), "select 1;\n")
      assert_empty app.missing_scripts_vs_origin
    end
  end

  # Nothing to compare against must read as "cannot tell", never as "you are
  # missing nothing" — the caller turns this into a refusal, and an unknown that
  # reads green is the exact false green being removed.
  def test_missing_scripts_vs_origin_is_nil_without_a_resolvable_origin_main
    app, dir = repo_with_scripts(["20260101000000.sql"])
    assert_nil app.origin_scripts
    assert_nil app.missing_scripts_vs_origin
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
