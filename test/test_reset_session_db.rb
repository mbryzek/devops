#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'open3'
require 'tmpdir'
load File.expand_path('../lib/common.rb', __dir__)

# Covers the pre-test database reset (ISS-801): which sbt invocations get one,
# which databases are eligible, and the bin/run wiring that carries it.
#
# THE TESTS THAT MATTER MOST HERE ARE THE NEGATIVE ONES. A reset drops a
# database, so every path where it must NOT happen is a path where a bug
# destroys data somebody wanted: `./run.sh run` restarting an app against state a
# developer put there deliberately, or — the unrecoverable one — a run pointed at
# :5432, which is Mike's own Postgres.app and never a session database.
#
# bin/reset-session-db is driven for real rather than reasoned about, because the
# whole value of the guard is that it fires (or does not) before sbt does, and
# only wiring can get that wrong. CLAUDE_DB_BIN stands in for claude-db so the
# test observes the decision without docker, an image and a container.
class TestResetSessionDb < Minitest::Test

  SESSION = "jdbc:postgresql://localhost:5702/platformdb_sess_abc".freeze
  SHARED  = "jdbc:postgresql://localhost:5432/platformdb".freeze

  # ---- which invocations are test runs ----

  # Narrower than opens_database? on the `run` side: `run`/`runMain` open a
  # database and must never be reset out from under.
  def test_run_tasks_are_not_test_runs
    [["run"], ["runMain", "core.Tool"], ["core/run"]].each do |args|
      assert SessionDb.opens_database?(args), "#{args.inspect} should still need a database"
      refute SessionDb.test_task?(args), "#{args.inspect} must not be treated as a test run"
    end
  end

  def test_test_tasks_in_every_shape_sbt_accepts
    [
      ["test"],
      ["test", "--fix"],
      ["core/test"],
      ["testQuick"],
      ["core/testOnly core.FooSpec"],
      ["clean", "test"],
      ["set core / Test / testOptions += x", "core/test"]
    ].each do |args|
      assert SessionDb.test_task?(args), "expected #{args.inspect} to be a test run"
    end
  end

  # Narrower than opens_database? on the other side too: compiling tests is not
  # running them, and there is nothing for a reset to do.
  def test_compiling_tests_is_not_a_test_run
    [["test:compile"], ["Test/compile"], ["core/test:compile"], ["compile"], [], ["clean"]].each do |args|
      refute SessionDb.test_task?(args), "expected #{args.inspect} not to be a test run"
    end
  end

  # ---- parsing the URL a reset has to agree with ----

  def test_parse_url_returns_the_port_and_database
    assert_equal [5702, "platformdb_sess_abc"], SessionDb.parse_url(SESSION)
    assert_equal [5432, "platformdb"], SessionDb.parse_url(SHARED)
    assert_equal [9999, "db"], SessionDb.parse_url("jdbc:postgresql://127.0.0.1:9999/db?ssl=false")
  end

  # A URL this tooling did not produce must read as "no match" rather than as a
  # partial one: reset only ever CHECKS a URL against a database it located for
  # itself, and a half-parsed answer there would let it drop the wrong database.
  def test_unparseable_urls_have_no_port_or_database
    ["", "jdbc:postgresql://localhost/platformdb", "postgres://localhost:5702/x", "nonsense"].each do |url|
      assert_equal [nil, nil], SessionDb.parse_url(url), "expected #{url.inspect} not to parse"
    end
  end

  # ---- wiring ----

  def bin(name)
    File.expand_path("../bin/#{name}", __dir__)
  end

  # A stub claude-db that records its argv instead of touching docker.
  def with_stub_claude_db(exit_code: 0)
    Dir.mktmpdir do |tmp|
      log  = File.join(tmp, "argv")
      stub = File.join(tmp, "claude-db")
      File.write(stub, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> #{log}
        exit #{exit_code}
      SH
      File.chmod(0o755, stub)
      yield stub, -> { File.exist?(log) ? File.read(log).split("\n") : [] }
    end
  end

  # A clean environment plus whatever the case sets, so the runner's own
  # CONF_DB_DEV_URL (this suite runs inside a Claude session, which has one)
  # cannot leak in and make a must-not-reset case reset.
  def run_reset(argv, env, stub)
    Open3.capture3(
      { SessionDb::CLAUDE_MARKER => nil,
        SessionDb::SESSION_URL => nil,
        'CLAUDE_DB_BIN' => stub }.merge(env),
      bin("reset-session-db"),
      *argv
    )
  end

  # 9 rather than 0, because bin/run's summary has to tell "reset" apart from
  # "there was nothing to reset" and both are success.
  PERFORMED = 9

  def test_a_test_run_on_a_session_database_is_reset_for_that_app
    with_stub_claude_db do |stub, calls|
      out, _err, status = run_reset(%w[platform test], { SessionDb::SESSION_URL => SESSION }, stub)
      assert_equal PERFORMED, status.exitstatus
      assert_equal ["reset --app platform"], calls.call
      assert_includes out, "Resetting the session database"
    end
  end

  # THE ONE THAT CANNOT REGRESS. :5432 is Mike's own database; it is not a
  # session database and nothing here may ever drop it.
  def test_the_shared_5432_database_is_never_reset
    with_stub_claude_db do |stub, calls|
      _out, _err, status = run_reset(%w[platform test], { SessionDb::SESSION_URL => SHARED }, stub)
      assert_equal 0, status.exitstatus
      assert_empty calls.call
    end
  end

  def test_nothing_happens_without_a_session_url
    with_stub_claude_db do |stub, calls|
      _out, _err, status = run_reset(%w[platform test], {}, stub)
      assert_equal 0, status.exitstatus
      assert_empty calls.call
    end
  end

  def test_starting_the_app_does_not_reset_its_database
    with_stub_claude_db do |stub, calls|
      _out, _err, status = run_reset(%w[platform run], { SessionDb::SESSION_URL => SESSION }, stub)
      assert_equal 0, status.exitstatus
      assert_empty calls.call
    end
  end

  def test_compiling_does_not_reset
    with_stub_claude_db do |stub, calls|
      _out, _err, status = run_reset(["platform", "test:compile"], { SessionDb::SESSION_URL => SESSION }, stub)
      assert_equal 0, status.exitstatus
      assert_empty calls.call
    end
  end

  # claude-db's own refusals name a real problem with the database this run is
  # about to use — a live connection, a URL that points somewhere else — and
  # running the suite anyway would measure that problem instead of the code.
  def test_a_refused_reset_fails_the_run
    with_stub_claude_db(:exit_code => 1) do |stub, _calls|
      _out, _err, status = run_reset(%w[platform test], { SessionDb::SESSION_URL => SESSION }, stub)
      # 1, not merely nonzero: PERFORMED is nonzero too, and a refusal that
      # exited 9 would be read by bin/run as a successful reset.
      assert_equal 1, status.exitstatus
    end
  end

  # ...but a reset that could not be ATTEMPTED is preparation that did not
  # happen, not a verdict on the database. Turning a working `./run.sh test` into
  # a failure over a missing sibling script would be a worse bug than the one the
  # reset fixes.
  def test_an_unrunnable_claude_db_does_not_fail_the_run
    Dir.mktmpdir do |tmp|
      _out, err, status = run_reset(%w[platform test],
                                    { SessionDb::SESSION_URL => SESSION },
                                    File.join(tmp, "does-not-exist"))
      assert_equal 0, status.exitstatus
      assert_includes err, "skipping the pre-test database reset"
    end
  end

  # ---- bin/run carries it, and says what happened ----

  # The directory name IS the app name (bin/run takes it from $PWD), so these run
  # in a directory called `platform`. It holds no build, so sbt finds nothing to
  # do and the run ends red — which is all these need: the assertions are about
  # what happened BEFORE sbt and about the summary line printed after it.
  def with_project
    Dir.mktmpdir do |tmp|
      project = File.join(tmp, "platform")
      Dir.mkdir(project)
      yield project
    end
  end

  def run_bin_run(project, stub, *args)
    Open3.capture3(
      { SessionDb::CLAUDE_MARKER => "1",
        SessionDb::SESSION_URL => SESSION,
        'CLAUDE_DB_BIN' => stub },
      bin("run"), *args,
      :chdir => project
    )
  end

  # --no-reset-db must reach bin/run and NOT reach sbt (which would fail on an
  # unknown command), and the summary has to say the database was left alone —
  # otherwise a run measured against a dirty database reads exactly like a clean
  # one, which is the whole failure ISS-801 describes.
  def test_run_skips_the_reset_when_asked_and_says_so
    with_stub_claude_db do |stub, calls|
      with_project do |project|
        out, _err, _status = run_bin_run(project, stub, "test", "--no-reset-db")
        assert_empty calls.call
        assert_includes out, "session db:     not reset (--no-reset-db)"
      end
    end
  end

  def test_run_resets_by_default_and_reports_it_in_the_summary
    with_stub_claude_db do |stub, calls|
      with_project do |project|
        out, _err, _status = run_bin_run(project, stub, "test")
        assert_equal ["reset --app platform"], calls.call
        assert_includes out, "session db:     reset from template"
      end
    end
  end

  # A refusal stops bin/run BEFORE sbt: running the suite against a database
  # claude-db has just said something is wrong with would measure the database,
  # not the code.
  def test_run_stops_before_sbt_when_the_reset_is_refused
    with_stub_claude_db(:exit_code => 1) do |stub, calls|
      with_project do |project|
        out, _err, status = run_bin_run(project, stub, "test")
        assert_equal ["reset --app platform"], calls.call
        refute status.success?
        assert_includes out, "the session database could not be reset"
        refute_includes out, "test summary"
      end
    end
  end

  # bin/run is shared by every scala project, and a repo that adopts ./run.sh
  # without being a claude-db app has no session database to reset. Failing its
  # test run over that would be the reset breaking something it does not even
  # apply to.
  def test_a_project_that_is_not_a_claude_db_app_is_left_alone
    with_stub_claude_db do |stub, calls|
      Dir.mktmpdir do |tmp|
        project = File.join(tmp, "notanapp#{Process.pid}")
        Dir.mkdir(project)
        _out, _err, status = Open3.capture3(
          { SessionDb::CLAUDE_MARKER => nil,
            SessionDb::SESSION_URL => SESSION,
            'CLAUDE_DB_BIN' => stub },
          bin("reset-session-db"), "notanapp#{Process.pid}", "test",
          :chdir => project
        )
        assert_equal 0, status.exitstatus
        assert_empty calls.call
      end
    end
  end
end
