#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# What ISS-578 actually was: `doctl registry login` writes the registry
# credential into Docker's credential store, and on a machine whose store is the
# Docker Desktop helper that call never returns. It does not fail — it hangs, so
# a session sits in it with no output until someone notices hours later.
#
# These tests guard the two halves of the fix that are easy to regress:
# credentials never travel through a credential helper, and the minted token
# never reaches a console, a log or a world-readable file.
class TestRegistryAuth < Minitest::Test
  include DevTestSupport

  ENV_KEYS = ["DOCKER_CONFIG", RegistryAuth::SCOPE_ENV, RegistryAuth::SOURCE_ENV].freeze

  # A credential-helper-free config, shaped exactly like `doctl registry
  # docker-config` output.
  MINTED = {
    "auths" => { "registry.digitalocean.com" => { "auth" => "ZGVhZGJlZWY6dG9rZW4=" } }
  }.freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    @source = Dir.mktmpdir("test-docker-config")
    @shadows = []
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.remove_entry(@source) if @source && File.exist?(@source)
    @shadows.each { |d| FileUtils.remove_entry(d) if File.exist?(d) }
  end

  # A realistic Docker config directory: a credential-helper-backed config.json
  # plus the sibling state (contexts, buildx) that docker needs to find the
  # right daemon and the right builder.
  def seed_source(config = nil)
    config ||= {
      "auths" => { "registry.digitalocean.com" => {} },
      "credsStore" => "desktop",
      "currentContext" => "desktop-linux",
      "plugins" => { "debug" => { "hooks" => "exec" } }
    }
    File.write(File.join(@source, "config.json"), JSON.generate(config))
    FileUtils.mkdir_p(File.join(@source, "contexts", "meta"))
    FileUtils.mkdir_p(File.join(@source, "buildx"))
    File.write(File.join(@source, "daemon.json"), "{}")
  end

  # Run `authenticate!` with doctl answered from `stdout`/`outcome`, recording
  # the argv it was asked to run. `at_exit` cleanup means the shadow dir would
  # outlive the test, so remember it for teardown instead.
  def authenticate(read_write:, stdout: JSON.generate(MINTED), outcome: :ok)
    calls = []
    dir = nil
    stub_singleton(Util, :assert_installed, ->(*) {}) do
      stub_singleton(Util, :run_with_timeout, lambda { |cmd, **kwargs|
        calls << { :cmd => cmd, :kwargs => kwargs }
        [stdout, outcome]
      }) do
        ENV[RegistryAuth::SOURCE_ENV] = @source
        dir = RegistryAuth.authenticate!(:read_write => read_write)
      end
    end
    @shadows << dir if dir
    [dir, calls]
  end

  def config_in(dir)
    JSON.parse(File.read(File.join(dir, "config.json")))
  end

  # ── the bug itself ─────────────────────────────────────────────────────────

  # The single most important assertion in this file. `doctl registry login` is
  # the call that hangs; nothing here may reintroduce it, under any flag.
  def test_never_runs_doctl_registry_login
    seed_source
    _, calls = authenticate(:read_write => false)
    joined = calls.map { |c| c[:cmd].join(" ") }
    refute_includes joined.join("\n"), "registry login"
    assert_equal ["doctl registry docker-config --expiry-seconds #{RegistryAuth::EXPIRY_SECONDS}"], joined
  end

  # The other half: even a config we generated is useless if docker is still
  # told to resolve credentials through a helper.
  def test_written_config_names_no_credential_helper
    seed_source
    dir, = authenticate(:read_write => false)
    config = config_in(dir)
    refute config.key?("credsStore"), "credsStore must not survive into the shadow config"
    refute config.key?("credHelpers"), "credHelpers must not survive into the shadow config"
    assert_equal MINTED["auths"], config["auths"]
  end

  # A shadow that drops currentContext silently moves every later docker command
  # off the Docker Desktop daemon and onto the default socket.
  def test_preserves_non_credential_settings
    seed_source
    dir, = authenticate(:read_write => false)
    config = config_in(dir)
    assert_equal "desktop-linux", config["currentContext"]
    assert_equal({ "debug" => { "hooks" => "exec" } }, config["plugins"])
  end

  # buildx state and context metadata must still resolve, and as symlinks — so
  # what a push writes lands in the real directory and is there next run.
  def test_shadows_sibling_state_as_symlinks
    seed_source
    dir, = authenticate(:read_write => false)
    ["contexts", "buildx", "daemon.json"].each do |name|
      path = File.join(dir, name)
      assert File.symlink?(path), "#{name} should be symlinked into the shadow dir"
      assert_equal File.join(@source, name), File.readlink(path)
    end
    refute File.symlink?(File.join(dir, "config.json")), "config.json must be ours, not the real one"
  end

  # ── the credential is a secret ─────────────────────────────────────────────

  # Captured, never streamed: Util.run would echo it to the console and append
  # it to the quiet-mode release log.
  def test_mints_with_output_captured_not_streamed
    seed_source
    _, calls = authenticate(:read_write => false)
    assert_equal true, calls.first[:kwargs][:capture]
  end

  def test_credential_file_is_not_readable_by_others
    seed_source
    dir, = authenticate(:read_write => false)
    assert_equal 0600, File.stat(File.join(dir, "config.json")).mode & 0777
    assert_equal 0700, File.stat(dir).mode & 0777
  end

  # A permanent token accumulates in the DO token list forever. The whole point
  # of minting per run is that a leaked copy expires on its own.
  def test_never_mints_a_permanent_token
    seed_source
    _, calls = authenticate(:read_write => true)
    joined = calls.map { |c| c[:cmd].join(" ") }.join("\n")
    refute_includes joined, "--never-expire"
    assert_includes joined, "--expiry-seconds"
  end

  # ── scope ──────────────────────────────────────────────────────────────────

  def test_pull_only_by_default_and_push_scope_on_request
    seed_source
    _, ro = authenticate(:read_write => false)
    refute_includes ro.first[:cmd], "--read-write"

    ENV.delete(RegistryAuth::SCOPE_ENV)
    _, rw = authenticate(:read_write => true)
    assert_includes rw.first[:cmd], "--read-write"
  end

  def test_exports_docker_config_and_scope_for_child_processes
    seed_source
    dir, = authenticate(:read_write => false)
    assert_equal dir, ENV["DOCKER_CONFIG"]
    assert_equal "ro", ENV[RegistryAuth::SCOPE_ENV]
    assert_equal @source, ENV[RegistryAuth::SOURCE_ENV]
  end

  # claude-db mints pull-only, then self-heals by shelling out to `db-image
  # --push`. The child must NOT reuse the parent's pull-only credential.
  def test_push_scope_remints_over_an_inherited_pull_only_credential
    seed_source
    _, = authenticate(:read_write => false)
    assert_equal "ro", ENV[RegistryAuth::SCOPE_ENV]

    _, calls = authenticate(:read_write => true)
    assert_includes calls.first[:cmd], "--read-write"
    assert_equal "rw", ENV[RegistryAuth::SCOPE_ENV]
  end

  # The reverse is pure waste: push credentials already cover a pull.
  def test_reuses_an_inherited_push_credential_for_a_pull
    seed_source
    dir, = authenticate(:read_write => true)

    calls = []
    stub_singleton(Util, :run_with_timeout, ->(cmd, **kw) { calls << cmd; [nil, :ok] }) do
      assert_equal dir, RegistryAuth.authenticate!(:read_write => false)
    end
    assert_empty calls, "a pull must not re-mint when push credentials are already in the environment"
  end

  # An inherited DOCKER_CONFIG whose directory is gone — a parent that exited and
  # cleaned up — must re-mint rather than hand back a dead path.
  def test_remints_when_the_inherited_config_no_longer_exists
    seed_source
    ENV["DOCKER_CONFIG"] = File.join(@source, "does-not-exist")
    ENV[RegistryAuth::SCOPE_ENV] = "rw"
    _, calls = authenticate(:read_write => false)
    refute_empty calls
  end

  # ── failure is loud ────────────────────────────────────────────────────────

  # The behaviour the issue asked for: bounded, and when the bound is hit, say
  # what to run. A hang produces no artifact at all.
  def test_mint_timeout_exits_with_the_remediation_command
    seed_source
    err, status = capture_stderr_and_exit do
      authenticate(:read_write => false, :stdout => nil, :outcome => :timed_out)
    end
    assert_equal 1, status
    assert_includes err, "doctl auth init"
    assert_includes err, "#{RegistryAuth::MINT_TIMEOUT_SECONDS}s"
  end

  def test_mint_failure_exits_rather_than_writing_an_unauthenticated_config
    seed_source
    err, status = capture_stderr_and_exit do
      authenticate(:read_write => false, :stdout => nil, :outcome => :failed)
    end
    assert_equal 1, status
    assert_includes err, "doctl account get"
  end

  # doctl exiting 0 with output we cannot use is a failure, not a config to
  # write — otherwise the pull fails later with an opaque 401.
  def test_unparseable_or_empty_doctl_output_is_a_failure
    seed_source
    ["not json at all", JSON.generate("auths" => {})].each do |stdout|
      err, status = capture_stderr_and_exit do
        authenticate(:read_write => false, :stdout => stdout)
      end
      assert_equal 1, status, "expected #{stdout.inspect} to abort"
      assert_includes err, "doctl account get"
    end
  end

  # A box with no ~/.docker at all still has to work.
  def test_works_when_the_source_config_dir_does_not_exist
    ENV[RegistryAuth::SOURCE_ENV] = File.join(@source, "absent")
    calls = []
    dir = nil
    stub_singleton(Util, :assert_installed, ->(*) {}) do
      stub_singleton(Util, :run_with_timeout, lambda { |cmd, **kw|
        calls << cmd
        [JSON.generate(MINTED), :ok]
      }) do
        dir = RegistryAuth.authenticate!(:read_write => false)
      end
    end
    @shadows << dir
    assert_equal MINTED["auths"], config_in(dir)["auths"]
  end
end

# Util.registry_login is now a one-line alias kept for its five push call sites.
class TestUtilRegistryLogin < Minitest::Test
  include DevTestSupport

  def test_asks_for_push_scope
    scopes = []
    stub_singleton(RegistryAuth, :authenticate!, ->(read_write:) { scopes << read_write; "/tmp/x" }) do
      Util.registry_login
    end
    assert_equal [true], scopes
  end
end
