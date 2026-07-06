#!/usr/bin/env ruby
require 'minitest/autorun'
require 'json'
require 'codegen/api_config'
load File.expand_path('../bin/dev', __dir__)

class TestDevCodegen < Minitest::Test
  def test_parse_codegen_sync_defaults
    o = parse_codegen_sync_args([])
    assert_nil o[:app]
    assert_equal 4, o[:concurrency]
    refute o[:dry_run]
    refute o[:regen_only]
    refute o[:full_tests]
  end

  def test_parse_codegen_sync_all_flags
    o = parse_codegen_sync_args(%w[--app rallyd --concurrency 2 --dry-run --regen-only --full-tests])
    assert_equal "rallyd", o[:app]
    assert_equal 2, o[:concurrency]
    assert o[:dry_run]
    assert o[:regen_only]
    assert o[:full_tests]
  end

  def test_parse_codegen_sync_rejects_unknown
    assert_raises(SystemExit) { parse_codegen_sync_args(["--bogus"]) }
  end

  def test_parse_codegen_sync_requires_app_value
    assert_raises(SystemExit) { parse_codegen_sync_args(["--app"]) }
  end

  def test_parse_codegen_sync_rejects_zero_concurrency
    assert_raises(SystemExit) { parse_codegen_sync_args(["--concurrency", "0"]) }
  end
end

class TestApiConfig < Minitest::Test
  def load_fixture(name)
    Codegen::ApiConfig.parse(JSON.parse(File.read(File.expand_path("fixtures/codegen/#{name}.json", __dir__))))
  end

  def test_backend_produced_names
    cfg = load_fixture("backend")
    assert_includes cfg.produced_names, "platform"
    assert_includes cfg.produced_names, "rallyd-api"
    assert_includes cfg.produced_names, "platform-internal"
    assert_empty cfg.consumed_names
  end

  def test_backend_target_dirs
    cfg = load_fixture("backend")
    assert_includes cfg.target_dirs, "api/app/generated"
    assert_includes cfg.target_dirs, "dao/psql"
  end

  def test_consumer_consumed_names_and_dirs
    cfg = load_fixture("consumer")
    assert_includes cfg.consumed_names, "platform"
    assert_includes cfg.consumed_names, "rallyd-api"
    assert_empty cfg.produced_names
    assert_includes cfg.target_dirs, "./src/generated"
    assert_includes cfg.target_dirs, "./playwright/generated"
  end
end
