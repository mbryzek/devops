#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/version_lock'

class TestVersionLock < Minitest::Test
  def teardown
    ENV.delete("APIBUILDER_VERSION_LOCK")
  end

  def test_key
    assert_equal "bryzek/platform", VersionLock.key("bryzek", "platform")
  end

  def test_path_honors_env_override
    ENV["APIBUILDER_VERSION_LOCK"] = "/tmp/custom-versions.lock"
    assert_equal "/tmp/custom-versions.lock", VersionLock.path("/some/repo")
  end

  def test_read_missing_file_returns_empty
    Dir.mktmpdir do |dir|
      ENV["APIBUILDER_VERSION_LOCK"] = File.join(dir, "absent.lock")
      assert_equal({}, VersionLock.read("/x"))
    end
  end

  def test_write_then_read_roundtrip
    Dir.mktmpdir do |dir|
      ENV["APIBUILDER_VERSION_LOCK"] = File.join(dir, ".apibuilder", "versions.lock")
      path = VersionLock.write("/x", { "bryzek/platform" => "2026-01-01T00:00:00.000Z" })
      assert File.exist?(path)
      assert_equal({ "bryzek/platform" => "2026-01-01T00:00:00.000Z" }, VersionLock.read("/x"))
    end
  end

  def test_write_merges_and_overwrites_existing_keys
    Dir.mktmpdir do |dir|
      ENV["APIBUILDER_VERSION_LOCK"] = File.join(dir, "versions.lock")
      VersionLock.write("/x", { "bryzek/a" => "v1" })
      VersionLock.write("/x", { "bryzek/b" => "v2", "bryzek/a" => "v3" })
      assert_equal({ "bryzek/a" => "v3", "bryzek/b" => "v2" }, VersionLock.read("/x"))
    end
  end

  def test_write_empty_is_noop
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.lock")
      ENV["APIBUILDER_VERSION_LOCK"] = path
      assert_nil VersionLock.write("/x", {})
      refute File.exist?(path)
    end
  end

  def test_read_corrupt_file_returns_empty
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.lock")
      ENV["APIBUILDER_VERSION_LOCK"] = path
      IO.write(path, "not json{{{")
      assert_equal({}, VersionLock.read("/x"))
    end
  end

  def test_read_wrong_shape_json_returns_empty
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.lock")
      ENV["APIBUILDER_VERSION_LOCK"] = path
      IO.write(path, "[1, 2, 3]")
      assert_equal({}, VersionLock.read("/x"))
    end
  end

  def test_feature_root_falls_back_to_parent_when_not_a_git_repo
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      assert_equal File.expand_path(dir), VersionLock.feature_root(repo)
    end
  end
end
