#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'stringio'
require 'tmpdir'
load File.expand_path('../bin/dev', __dir__)

# Covers the `dev scripts` subcommand: discovery, the `dev-script:` metadata
# header (targets/app), description extraction, name resolution, and the
# env-target enforcement in `dev scripts run` (local default, refusal of
# undeclared targets). The actual psql / db-exec execution is not invoked here.
class TestDevScripts < Minitest::Test
  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    path
  end

  # ---- metadata / targets / description ----

  def test_metadata_parses_targets_and_app
    Dir.mktmpdir do |dir|
      path = write_script(dir, "x.sql", <<~SQL)
        -- dev-script: targets=local,production app=platform
        -- Truncate things.
        truncate table foo;
      SQL
      meta = script_metadata(path)
      assert_equal "local,production", meta["targets"]
      assert_equal "platform", meta["app"]
      assert_equal %w[local production], script_targets(meta)
    end
  end

  def test_targets_default_to_local_when_no_header
    Dir.mktmpdir do |dir|
      path = write_script(dir, "x.sql", "-- just a comment\nselect 1;\n")
      assert_equal ["local"], script_targets(script_metadata(path))
    end
  end

  def test_metadata_skips_shebang_for_executables
    Dir.mktmpdir do |dir|
      path = write_script(dir, "tool.sh", <<~SH)
        #!/usr/bin/env bash
        # dev-script: targets=local
        # Do a thing.
        echo hi
      SH
      assert_equal ["local"], script_targets(script_metadata(path))
      assert_equal "Do a thing.", script_description(path)
    end
  end

  def test_description_skips_metadata_line
    Dir.mktmpdir do |dir|
      path = write_script(dir, "x.sql", <<~SQL)
        -- dev-script: targets=local
        -- The real description.
        select 1;
      SQL
      assert_equal "The real description.", script_description(path)
    end
  end

  def test_script_base_strips_extension
    assert_equal "delete-test-clubs", script_base("delete-test-clubs.sql")
    assert_equal "tool", script_base("tool.sh")
    assert_equal "noext", script_base("noext")
  end

  # ---- discovery against the real scripts dir ----

  # These names must match the files committed in scripts/ — update if renamed.
  def test_available_scripts_include_seeded_and_exclude_readme
    names = scripts_available
    assert_includes names, "truncate-court-reserve-data.sql"
    # Wrappers (executables) are discovered the same as first-class scripts.
    assert_includes names, "delete-test-clubs"
    assert_includes names, "rename-xlsx-period"
    assert_includes names, "verify-data"
    refute_includes names, "README.md"
  end

  def test_resolve_wrapper_by_exact_name
    assert_equal File.join(SCRIPTS_DIR, "rename-xlsx-period"),
                 resolve_script("rename-xlsx-period")
  end

  def test_resolve_by_base_name
    assert_equal File.join(SCRIPTS_DIR, "truncate-court-reserve-data.sql"),
                 resolve_script("truncate-court-reserve-data")
  end

  # ---- run: env-target enforcement (no execution reached) ----

  def capture
    out = StringIO.new
    err = StringIO.new
    old_out = $stdout
    old_err = $stderr
    $stdout = out
    $stderr = err
    status = nil
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [out.string + err.string, status]
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  def test_run_refuses_undeclared_prod_target
    # A targets=local script must refuse --prod before any execution. Driven through
    # run_sql_script against a tmpdir fixture rather than through cmd_scripts_run against a
    # committed script: every .sql in scripts/ now declares production, and pinning this
    # behaviour to whichever file happens not to is what made it a casualty of deleting one.
    Dir.mktmpdir do |dir|
      path = write_script(dir, "local-only.sql", "-- dev-script: targets=local\n-- Local only.\nselect 1;\n")
      out, status = capture { run_sql_script(path, "local-only", ["--prod"]) }
      assert_equal 1, status
      assert_match(/does not support env 'production'/, out)
      assert_match(/Allowed: local/, out)
    end
  end

  def test_run_refuses_undeclared_development_target
    # truncate declares local,production but NOT development.
    out, status = capture { cmd_scripts_run(["truncate-court-reserve-data", "--env", "development"]) }
    assert_equal 1, status
    assert_match(/does not support env 'development'/, out)
  end

  def test_run_requires_a_name
    out, status = capture { cmd_scripts_run([]) }
    assert_equal 1, status
    assert_match(/requires a script name/, out)
  end

  def test_run_rejects_leading_flag_as_name
    # The name must come first; a leading flag is not a script name.
    out, status = capture { cmd_scripts_run(["--prod", "delete-test-clubs"]) }
    assert_equal 1, status
    assert_match(/requires a script name/, out)
  end

  def test_run_env_without_value_is_rejected
    out, status = capture { cmd_scripts_run(["truncate-court-reserve-data", "--env"]) }
    assert_equal 1, status
    assert_match(/--env requires a value/, out)
  end

  def test_run_rejects_args_for_sql_script
    out, status = capture { cmd_scripts_run(["truncate-court-reserve-data", "foo"]) }
    assert_equal 1, status
    assert_match(/is a SQL script; unexpected argument 'foo'/, out)
  end

  def test_delete_test_clubs_is_a_local_wrapper
    # It became a wrapper in ISS-827 — the utility itself is `POST /dev/local/test/club/deletions`
    # in platform. `targets=local` still holds and still means what it says here (the wrapper runs
    # on your machine), but what ENFORCES it is now the endpoint's own environment guard.
    path = File.join(SCRIPTS_DIR, "delete-test-clubs")
    assert File.executable?(path), "delete-test-clubs must be executable to be dispatched as a wrapper"
    assert_equal ["local"], script_targets(script_metadata(path))
    assert_match(/Delete every test-generated club/, script_description(path))
  end

  def test_run_unknown_script_suggests
    out, status = capture { cmd_scripts_run(["delete-test-club"]) }
    assert_equal 1, status
    assert_match(/Unknown script: delete-test-club \(did you mean 'delete-test-clubs'\?\)/, out)
  end
end
