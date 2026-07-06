#!/usr/bin/env ruby
require 'minitest/autorun'
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

class TestCodegenApiConfig < Minitest::Test
  def gen(key, target) = ApiConfig::Generator.new(key: key, target: target, attributes: {})
  def app(key) = ApiConfig::Application.new(key: key, file_path: nil)
  def block(gens, apps, group: nil)
    ApiConfig::Block.new(org: "bryzek", group: group, generators: gens, attributes: {}, applications: apps)
  end

  def test_backend_block_is_produced
    cfg = Codegen::ApiConfig.from_blocks([
      block([gen("play_controller", "api/app/generated"), gen("bryzek_play_client", "generated/app")],
            [app("platform"), app("rallyd-api")]),
    ])
    assert_includes cfg.produced_names, "platform"
    assert_includes cfg.produced_names, "rallyd-api"
    assert_empty cfg.consumed_names
    assert_includes cfg.target_dirs, "api/app/generated"
    assert_includes cfg.target_dirs, "generated/app"
  end

  def test_typescript_block_is_consumed
    cfg = Codegen::ApiConfig.from_blocks([
      block([gen("typescript", "./src/generated")], [app("platform"), app("rallyd-api")]),
    ])
    assert_includes cfg.consumed_names, "platform"
    assert_includes cfg.consumed_names, "rallyd-api"
    assert_empty cfg.produced_names
    assert_includes cfg.target_dirs, "./src/generated"
  end

  def test_dao_group_block_with_no_apps
    cfg = Codegen::ApiConfig.from_blocks([
      block([gen("psql_scala", "generated/app"), gen("psql_ddl", "dao/psql")], [], group: "dao"),
    ])
    assert_empty cfg.produced_names
    assert_empty cfg.consumed_names
    assert_includes cfg.target_dirs, "dao/psql"
  end

  def test_empty_generators_block_is_produced_not_consumed
    cfg = Codegen::ApiConfig.from_blocks([block([], [app("x")])])
    assert_includes cfg.produced_names, "x"
    assert_empty cfg.consumed_names
  end

  def test_load_against_real_config_shape
    # Integration through ::ApiConfig + real `pkl eval` on this repo's own
    # .api/config.pkl — a shape regression cannot pass this.
    cfg = Codegen::ApiConfig.load(File.expand_path('..', __dir__))
    refute_empty cfg.target_dirs
    refute_empty cfg.produced_names
  end
end
