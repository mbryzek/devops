#!/usr/bin/env ruby
require 'minitest/autorun'
require 'codegen/api_config'
require 'codegen/graph'
require 'codegen/sync'
require 'tmpdir'
require 'fileutils'
require 'pathname'
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

class TestGraph < Minitest::Test
  App = Struct.new(:name, :stack, :ignored, keyword_init: true)

  def build
    apps = [
      App.new(name: "platform", stack: :scala, ignored: false),
      App.new(name: "acumen",   stack: :scala, ignored: false),
      App.new(name: "rallyd",   stack: :sveltekit, ignored: false),
      App.new(name: "acumen-ui",stack: :elm, ignored: false),
      App.new(name: "ignored-x",stack: :sveltekit, ignored: true),
      App.new(name: "no-api",   stack: :sveltekit, ignored: false),
    ]
    configs = {
      "platform"  => Codegen::ApiConfig.new(produced_names: Set["platform","rallyd-api"], consumed_names: Set[], target_dirs: []),
      "acumen"    => Codegen::ApiConfig.new(produced_names: Set["acumen"], consumed_names: Set[], target_dirs: []),
      "rallyd"    => Codegen::ApiConfig.new(produced_names: Set[], consumed_names: Set["platform","rallyd-api"], target_dirs: []),
      "acumen-ui" => Codegen::ApiConfig.new(produced_names: Set[], consumed_names: Set["acumen"], target_dirs: []),
      "ignored-x" => Codegen::ApiConfig.new(produced_names: Set[], consumed_names: Set["platform"], target_dirs: []),
    }
    Codegen::Graph.build(apps: apps, configs: configs)
  end

  def test_backends_are_scala_repos_with_config
    assert_equal %w[acumen platform], build.backends.sort
  end

  def test_consumers_exclude_ignored_and_configless
    c = build.consumers
    assert_includes c, "rallyd"
    assert_includes c, "acumen-ui"
    refute_includes c, "ignored-x"
    refute_includes c, "no-api"
    refute_includes c, "platform"
  end

  def test_depends_on_maps_consumer_to_backend
    assert_equal ["platform"], build.depends_on("rallyd")
    assert_equal ["acumen"],   build.depends_on("acumen-ui")
  end
end

class TestSyncPaths < Minitest::Test
  def test_classify_diff
    assert_equal :in_sync, Codegen::Sync.classify_diff("")
    assert_equal :in_sync, Codegen::Sync.classify_diff("  \n")
    assert_equal :changed, Codegen::Sync.classify_diff(" M src/generated/x.ts\n")
  end

  def test_generated_paths_union_of_dirs_and_marker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/generated"))
      FileUtils.mkdir_p(File.join(dir, "src/hand"))
      File.write(File.join(dir, "src/generated/a.ts"), "// Generated by API Builder\n")
      File.write(File.join(dir, "src/hand/marked.ts"), "line1\n// Generated by API Builder - do not edit\n")
      File.write(File.join(dir, "src/hand/plain.ts"), "just my code\n")

      cfg = Codegen::ApiConfig.new(produced_names: Set[], consumed_names: Set["x"], target_dirs: ["./src/generated"])
      paths = Codegen::Sync.generated_paths(dir, cfg)

      assert_includes paths, File.join(dir, "src/generated/a.ts")      # via target dir
      assert_includes paths, File.join(dir, "src/hand/marked.ts")      # via marker
      refute_includes paths, File.join(dir, "src/hand/plain.ts")       # untouched
    end
  end

  def test_generated_paths_absolute_and_deduped_for_relative_repo_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/generated"))
      File.write(File.join(dir, "src/generated/a.ts"), "// Generated by API Builder\n") # matches BOTH branches
      cfg = Codegen::ApiConfig.new(produced_names: Set[], consumed_names: Set["x"], target_dirs: ["./src/generated"])
      Dir.chdir(File.dirname(dir)) do
        paths = Codegen::Sync.generated_paths(File.basename(dir), cfg)
        assert paths.all? { |p| Pathname.new(p).absolute? }, "expected all absolute: #{paths.inspect}"
        assert_equal paths.uniq.length, paths.length, "expected no duplicates: #{paths.inspect}"
        assert_equal 1, paths.length, "the both-matched file should appear exactly once"
      end
    end
  end
end

class TestFixPrompt < Minitest::Test
  def test_prompt_includes_core_directives
    p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "codegen-sync",
                                 verify_cmd: "npm run check", regen_only: false,
                                 build_error: "TS2322: type mismatch")
    assert_includes p, "rallyd"
    assert_includes p, "codegen-sync"
    assert_includes p, "npm run check"
    assert_includes p, "never edit generated files"
    assert_includes p, "TS2322: type mismatch"
    assert_includes p, "draft PR"
    assert_includes p, "Do NOT merge to main"
  end

  def test_regen_only_skips_completion_workflow
    p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "codegen-sync",
                                 verify_cmd: "npm run check", regen_only: true)
    refute_includes p, "code review"
  end
end
