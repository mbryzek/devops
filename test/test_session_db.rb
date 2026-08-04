#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'open3'
require 'tmpdir'
load File.expand_path('../lib/common.rb', __dir__)

# Covers the session-DB guard (lib/session_db.rb): which sbt tasks need a
# database, which JDBC URLs are the shared :5432 one, and the CLAUDECODE-keyed
# decision built from both. The last two tests run bin/assert-session-db and
# bin/run for real, because the whole value of the guard is that it fires before
# sbt does — and only wiring, not logic, can get that wrong.
class TestSessionDb < Minitest::Test

  SESSION = "jdbc:postgresql://localhost:5702/platformdb_sess_abc".freeze

  def agent(url = nil)
    env = { SessionDb::CLAUDE_MARKER => "1" }
    env[SessionDb::SESSION_URL] = url if url
    env
  end

  # ---- which tasks open a database ----

  def test_test_tasks_open_a_database
    [
      ["test"],
      ["test", "--fix"],
      ["core/test"],
      ["testQuick"],
      ["test:compile"],
      ["core/testOnly core.FooSpec"],
      ["clean", "test"],
      ["set core / Test / testOptions += x", "core/test"]
    ].each do |args|
      assert SessionDb.opens_database?(args), "expected #{args.inspect} to need a database"
    end
  end

  def test_run_tasks_open_a_database
    assert SessionDb.opens_database?(["run"])
    assert SessionDb.opens_database?(["runMain", "core.Tool"])
    assert SessionDb.opens_database?(["core/run"])
  end

  # A session doing DB-free work must not be made to boot a container for it:
  # a guard that fires on everything teaches the session to export a bogus URL.
  def test_tasks_that_touch_no_database_are_not_gated
    [
      [],
      ["compile"],
      ["core/compile"],
      ["scalafmtAll"],
      ["show core/fullClasspath"],
      ["clean"],
      ["--make-faster"]
    ].each do |args|
      refute SessionDb.opens_database?(args), "expected #{args.inspect} not to need a database"
    end
  end

  # ---- which URLs are the shared dev database ----

  def test_urls_without_a_port_or_on_5432_are_the_shared_database
    assert SessionDb.shared_default_url?("jdbc:postgresql://localhost/platformdb")
    assert SessionDb.shared_default_url?("jdbc:postgresql://localhost:5432/platformdb")
    assert SessionDb.shared_default_url?("jdbc:postgresql://127.0.0.1:5432/acumendb")
    assert SessionDb.shared_default_url?("")
  end

  def test_a_container_port_is_a_session_database
    assert_equal false, SessionDb.shared_default_url?(SESSION)
    assert_equal false, SessionDb.shared_default_url?("jdbc:postgresql://127.0.0.1:5500/acumendb_sess_x")
    assert_equal false, SessionDb.shared_default_url?("jdbc:postgresql://localhost:9999/db?ssl=false")
  end

  # ---- the decision ----

  def test_agent_running_tests_without_a_session_db_is_blocked
    assert_equal :unset, SessionDb.blocking_reason(:sbt_args => ["test"], :env => agent)
  end

  def test_blank_session_url_reads_as_unset
    assert_equal :unset, SessionDb.blocking_reason(:sbt_args => ["test"], :env => agent("  "))
  end

  def test_agent_pointed_at_the_shared_database_is_blocked
    reason = SessionDb.blocking_reason(
      :sbt_args => ["test"],
      :env => agent("jdbc:postgresql://localhost:5432/platformdb")
    )
    assert_equal :shared, reason
  end

  def test_agent_with_a_session_database_may_run
    assert_nil SessionDb.blocking_reason(:sbt_args => ["test"], :env => agent(SESSION))
  end

  def test_agent_compiling_is_never_blocked
    assert_nil SessionDb.blocking_reason(:sbt_args => ["compile"], :env => agent)
  end

  # Mike's runs are the reason this keys on the caller rather than on the port:
  # :5432 is his database on purpose, so an interactive run must see nothing.
  def test_an_interactive_run_is_never_blocked
    assert_nil SessionDb.blocking_reason(:sbt_args => ["test"], :env => {})
    assert_nil SessionDb.blocking_reason(
      :sbt_args => ["test"],
      :env => { SessionDb::SESSION_URL => "jdbc:postgresql://localhost/platformdb" }
    )
    assert_nil SessionDb.blocking_reason(:sbt_args => ["test"], :env => { SessionDb::CLAUDE_MARKER => "  " })
  end

  # ---- the message ----

  def test_message_names_the_app_to_start_a_database_for
    message = SessionDb.message(:app => "acumen", :reason => :unset)
    assert_includes message, "claude-db start --app acumen"
    assert_includes message, SessionDb::SESSION_URL
  end

  def test_shared_message_quotes_the_offending_url
    message = SessionDb.message(
      :app => "platform",
      :reason => :shared,
      :url => "jdbc:postgresql://localhost:5432/platformdb"
    )
    assert_includes message, "jdbc:postgresql://localhost:5432/platformdb"
    assert_includes message, "#{DbPorts::RANGE_MIN}-#{DbPorts::RANGE_MAX}"
  end

  # ---- wiring ----

  def bin(name)
    File.expand_path("../bin/#{name}", __dir__)
  end

  # A clean environment plus whatever the case under test sets, so the runner's
  # own CONF_DB_DEV_URL (this suite runs inside a Claude session) cannot leak in
  # and make a blocking case pass.
  def run_bin(argv, env, dir: Dir.pwd)
    Open3.capture3(
      { SessionDb::CLAUDE_MARKER => nil, SessionDb::SESSION_URL => nil }.merge(env),
      *argv,
      :chdir => dir
    )
  end

  def test_assert_session_db_exits_nonzero_with_the_reason_on_stderr
    _out, err, status = run_bin([bin("assert-session-db"), "platform", "test"], agent)
    refute status.success?
    assert_includes err, "refusing to run sbt against the shared :5432 dev database"
    assert_includes err, "claude-db start --app platform"

    _out, err, status = run_bin([bin("assert-session-db"), "platform", "test"], agent(SESSION))
    assert status.success?
    assert_empty err
  end

  # bin/run must refuse BEFORE it starts sbt or opens a log — that is the whole
  # point of guarding in the wrapper rather than at application startup. sbt is
  # never reachable here, so the test costs nothing and needs no stub.
  #
  # The project directory is named uniquely rather than "platform" so the log
  # check below cannot see (or delete) a real platform run's log.
  def test_run_refuses_before_reaching_sbt
    Dir.mktmpdir do |tmp|
      name = "guardproj#{Process.pid}"
      project = File.join(tmp, name)
      Dir.mkdir(project)

      _out, err, status = run_bin([bin("run"), "test"], agent, :dir => project)

      refute status.success?
      assert_includes err, "refusing to run sbt against the shared :5432 dev database"
      assert_includes err, "claude-db start --app #{name}"
      assert_empty Dir.glob("/tmp/#{name}-test-*.log"),
                   "the guard let bin/run get as far as opening a log"
    end
  end
end
