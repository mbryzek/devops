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

  def test_app_names_collected_across_blocks
    cfg = Codegen::ApiConfig.from_blocks([
      block([gen("play_controller", "api/app/generated"), gen("bryzek_play_client", "generated/app")],
            [app("platform"), app("rallyd-api")]),
      block([gen("typescript", "./src/generated")], [app("acumen-api")]),
    ])
    assert_equal Set["platform", "rallyd-api", "acumen-api"], cfg.app_names
  end

  # Classification is generator-agnostic: whether a block uses typescript,
  # elm_v2, play_controller, or a not-yet-invented key, its apps land in
  # app_names all the same. Role (backend vs consumer) is decided by stack in
  # Codegen::Graph — the source of truth for generator keys lives in platform's
  # GeneratorsService, so nothing here needs to know or track them.
  def test_app_names_are_generator_key_agnostic
    %w[typescript elm_v2 play_controller elm_v99_future].each do |key|
      cfg = Codegen::ApiConfig.from_blocks([block([gen(key, "d")], [app("a")])])
      assert_equal Set["a"], cfg.app_names, "app_names must not depend on generator key #{key}"
    end
  end

  def test_dao_group_block_has_no_apps
    cfg = Codegen::ApiConfig.from_blocks([
      block([gen("psql_scala", "generated/app"), gen("psql_ddl", "dao/psql")], [], group: "dao"),
    ])
    assert_empty cfg.app_names
  end

  def test_load_against_real_config_shape
    # Integration through ::ApiConfig + real `pkl eval` on this repo's own
    # .api/config.pkl — a shape regression cannot pass this.
    cfg = Codegen::ApiConfig.load(File.expand_path('..', __dir__))
    refute_empty cfg.app_names
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
      "platform"  => Codegen::ApiConfig.new(app_names: Set["platform", "rallyd-api"]),
      "acumen"    => Codegen::ApiConfig.new(app_names: Set["acumen"]),
      "rallyd"    => Codegen::ApiConfig.new(app_names: Set["platform", "rallyd-api"]),
      "acumen-ui" => Codegen::ApiConfig.new(app_names: Set["acumen"]),
      "ignored-x" => Codegen::ApiConfig.new(app_names: Set["platform"]),
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

  # acumen-ui is an :elm consumer — this is the edge the elm/elm_v2 generator-key
  # bug used to drop. Now that roles come from stack + app-name overlap, it holds
  # regardless of which generator key acumen-ui uses.
  def test_depends_on_maps_consumer_to_backend
    assert_equal ["platform"], build.depends_on("rallyd")
    assert_equal ["acumen"],   build.depends_on("acumen-ui")
  end

  # Robustness: a consumer whose config uses a brand-new/unknown generator key
  # still gets its backend edge, because Graph classifies by stack + app-name
  # overlap, never by generator key (the failure class of the old allowlist).
  def test_edge_survives_unknown_generator_key
    fe_block = ApiConfig::Block.new(
      org: "bryzek", group: nil,
      generators: [ApiConfig::Generator.new(key: "elm_v99_future", target: "d", attributes: {})],
      attributes: {}, applications: [ApiConfig::Application.new(key: "platform", file_path: nil)],
    )
    apps = [
      App.new(name: "platform", stack: :scala, ignored: false),
      App.new(name: "newfe",    stack: :elm,   ignored: false),
    ]
    configs = {
      "platform" => Codegen::ApiConfig.new(app_names: Set["platform"]),
      "newfe"    => Codegen::ApiConfig.from_blocks([fe_block]),
    }
    g = Codegen::Graph.build(apps: apps, configs: configs)
    assert_equal ["platform"], g.depends_on("newfe")
  end
end

class TestSyncPaths < Minitest::Test
  def test_classify_diff
    assert_equal :in_sync, Codegen::Sync.classify_diff("")
    assert_equal :in_sync, Codegen::Sync.classify_diff("  \n")
    assert_equal :changed, Codegen::Sync.classify_diff(" M src/generated/x.ts\n")
  end

  def test_open_codegen_pr_url_finds_matching_head
    json = [
      { "url" => "https://github.com/mbryzek/acumen/pull/9", "headRefName" => "some-other-branch" },
      { "url" => "https://github.com/mbryzek/acumen/pull/108", "headRefName" => "codegen-sync-20260706-142530" },
    ].to_json
    assert_equal "https://github.com/mbryzek/acumen/pull/108",
                 Codegen::Sync.open_codegen_pr_url(json, "codegen-sync")
  end

  def test_open_codegen_pr_url_nil_when_none_match
    json = [{ "url" => "u", "headRefName" => "feature-x" }].to_json
    assert_nil Codegen::Sync.open_codegen_pr_url(json, "codegen-sync")
    assert_nil Codegen::Sync.open_codegen_pr_url("[]", "codegen-sync")
  end

  def test_open_codegen_pr_url_nil_on_garbage
    assert_nil Codegen::Sync.open_codegen_pr_url("not json", "codegen-sync")
    assert_nil Codegen::Sync.open_codegen_pr_url("", "codegen-sync")
  end

  TIMESTAMP_DIFF = <<~DIFF
    diff --git a/api/app/generated/PlayControllerComBryzekAcumenApi.scala b/api/app/generated/PlayControllerComBryzekAcumenApi.scala
    --- a/api/app/generated/PlayControllerComBryzekAcumenApi.scala
    +++ b/api/app/generated/PlayControllerComBryzekAcumenApi.scala
    @@ -1,6 +1,6 @@
     /**
       * Generated by API Builder - https://www.apibuilder.io
    -  * Service version: 2026-05-13T10:31:37.560-04:00
    +  * Service version: 2026-07-06T20:10:20.166Z
       * User agent: apibuilder ...
      */
  DIFF

  CODE_DIFF = <<~DIFF
    --- a/x.scala
    +++ b/x.scala
    @@ -10,3 +10,3 @@
       * doc comment tweaked
    -  val limit = 10
    +  val limit = 25
  DIFF

  def test_comment_only_diff_true_for_timestamp
    assert Codegen::Sync.comment_only_diff?(TIMESTAMP_DIFF)
  end

  def test_comment_only_diff_false_for_code_change
    refute Codegen::Sync.comment_only_diff?(CODE_DIFF)
  end

  def test_comment_only_diff_false_for_empty
    refute Codegen::Sync.comment_only_diff?("")
  end

  def test_comment_only_diff_handles_routes_and_elm_comments
    routes = "--- a/r\n+++ b/r\n@@ -1 +1 @@\n-# Service version: a\n+# Service version: b\n"
    elm = "--- a/e\n+++ b/e\n@@ -1 +1 @@\n--- Service version: a\n+-- Service version: b\n"
    assert Codegen::Sync.comment_only_diff?(routes)
    assert Codegen::Sync.comment_only_diff?(elm)
  end

  def test_generated_paths_marker_only
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/generated"))
      FileUtils.mkdir_p(File.join(dir, "src/hand"))
      File.write(File.join(dir, "src/generated/a.ts"), "// Generated by API Builder\n")
      File.write(File.join(dir, "src/hand/marked.ts"), "line1\n// Generated by API Builder - do not edit\n")
      File.write(File.join(dir, "src/hand/plain.ts"), "just my code\n")

      paths = Codegen::Sync.generated_paths(dir)

      assert_includes paths, File.join(dir, "src/generated/a.ts")
      assert_includes paths, File.join(dir, "src/hand/marked.ts")
      refute_includes paths, File.join(dir, "src/hand/plain.ts")
    end
  end

  # Regression: a hand-written file living inside a generator output dir
  # (e.g. platform's api/conf holds hand-written application.conf next to
  # generated *.routes) must NOT be wiped. Marker-only deletion guarantees it.
  def test_generated_paths_spares_handwritten_file_in_generated_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api/conf"))
      File.write(File.join(dir, "api/conf/platform.routes"), "# Generated by API Builder\nGET /x\n")
      File.write(File.join(dir, "api/conf/application.conf"), "include \"devtest.conf\"\n") # hand-written, no marker

      paths = Codegen::Sync.generated_paths(dir)

      assert_includes paths, File.join(dir, "api/conf/platform.routes")
      refute_includes paths, File.join(dir, "api/conf/application.conf")
    end
  end

  def test_generated_paths_absolute_and_deduped_for_relative_repo_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src/generated"))
      File.write(File.join(dir, "src/generated/a.ts"), "// Generated by API Builder\n")
      Dir.chdir(File.dirname(dir)) do
        paths = Codegen::Sync.generated_paths(File.basename(dir))
        assert paths.all? { |p| Pathname.new(p).absolute? }, "expected all absolute: #{paths.inspect}"
        assert_equal paths.uniq.length, paths.length, "expected no duplicates: #{paths.inspect}"
        assert_equal 1, paths.length
      end
    end
  end
end

class TestVerifyCmd < Minitest::Test
  def test_scala_default_is_compile
    assert_equal "sbt Test/compile", Codegen::Sync.verify_cmd_for(:scala, full_tests: false)
  end
  def test_scala_full_tests
    assert_equal "sbt test", Codegen::Sync.verify_cmd_for(:scala, full_tests: true)
  end
  def test_sveltekit_and_elm
    assert_equal "npm run check", Codegen::Sync.verify_cmd_for(:sveltekit, full_tests: false)
    assert_equal "./review.sh",   Codegen::Sync.verify_cmd_for(:elm, full_tests: false)
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

class TestCodegenSummary < Minitest::Test
  def test_rows_sorted_with_full_urls
    results = {
      "rallyd"    => { status: :pr_opened, pr_url: "https://github.com/mbryzek/rallyd/pull/5" },
      "acumen"    => { status: :in_sync },
      "hackathon" => { status: :needs_attention, error: "compile failed" },
    }
    rows = codegen_status_rows(results)
    assert_equal %w[acumen hackathon rallyd], rows.map(&:first)
    assert_includes rows.flatten, "https://github.com/mbryzek/rallyd/pull/5"
    refute(rows.flatten.any? { |c| c.to_s.match?(/\A\w[\w-]*#\d+\z/) }) # no repo#NN shorthand — full URLs only
  end

  def test_rows_use_dash_when_no_pr_url
    rows = codegen_status_rows({ "acumen" => { status: :in_sync } })
    assert_equal [["acumen", "in_sync", "-"]], rows
  end

  def test_write_codegen_status_json_writes_valid_json_with_four_keys
    results = {
      "rallyd"    => { status: :pr_opened, pr_url: "https://github.com/mbryzek/rallyd/pull/5" },
      "acumen"    => { status: :in_sync },
      "hackathon" => { status: :needs_attention, error: "compile failed" },
    }
    Dir.mktmpdir do |dir|
      write_codegen_status_json(dir, results)
      path = File.join(dir, "codegen-sync-status.json")
      assert File.exist?(path)
      data = JSON.parse(File.read(path))
      assert_equal 3, data.length
      data.each { |row| assert_equal %w[error pr_url repo status].sort, row.keys.sort }

      rallyd = data.find { |row| row["repo"] == "rallyd" }
      assert_equal "pr_opened", rallyd["status"]
      assert_equal "https://github.com/mbryzek/rallyd/pull/5", rallyd["pr_url"]
      assert_nil rallyd["error"]

      hackathon = data.find { |row| row["repo"] == "hackathon" }
      assert_equal "needs_attention", hackathon["status"]
      assert_equal "compile failed", hackathon["error"]
      assert_nil hackathon["pr_url"]
    end
  end
end

class TestCodegenRunPlan < Minitest::Test
  App = Struct.new(:name, :stack, :ignored, keyword_init: true)
  Target = Struct.new(:name, :stack, keyword_init: true)

  # Two backends (platform, acumen), two consumers each tied to a DIFFERENT
  # backend (rallyd -> platform, acumen-ui -> acumen), plus one consumer
  # candidate ("no-api") with no parsed config so it never enters the graph.
  def build
    apps = [
      App.new(name: "platform",  stack: :scala,     ignored: false),
      App.new(name: "acumen",    stack: :scala,      ignored: false),
      App.new(name: "rallyd",    stack: :sveltekit,  ignored: false),
      App.new(name: "acumen-ui", stack: :elm,        ignored: false),
      App.new(name: "no-api",    stack: :sveltekit,  ignored: false),
    ]
    configs = {
      "platform"  => Codegen::ApiConfig.new(app_names: Set["platform", "rallyd-api"]),
      "acumen"    => Codegen::ApiConfig.new(app_names: Set["acumen"]),
      "rallyd"    => Codegen::ApiConfig.new(app_names: Set["platform", "rallyd-api"]),
      "acumen-ui" => Codegen::ApiConfig.new(app_names: Set["acumen"]),
    }
    Codegen::Graph.build(apps: apps, configs: configs)
  end

  def test_full_sweep_runs_every_backend_and_consumer
    plan = codegen_run_plan(nil, build)
    assert_equal %w[acumen platform], plan[:backends]
    assert_equal %w[acumen-ui rallyd], plan[:consumers]
    assert_equal %w[acumen acumen-ui platform rallyd].sort, plan[:run_names].sort
  end

  def test_consumer_target_runs_only_itself
    target = Target.new(name: "rallyd", stack: :sveltekit)
    plan = codegen_run_plan(target, build)
    assert_empty plan[:backends]
    assert_equal ["rallyd"], plan[:consumers]
    refute_empty plan[:run_names]
  end

  def test_backend_target_runs_itself_plus_only_dependent_consumers
    target = Target.new(name: "platform", stack: :scala)
    plan = codegen_run_plan(target, build)
    assert_equal ["platform"], plan[:backends]
    # rallyd depends on platform -> included. acumen-ui depends on acumen
    # (a DIFFERENT backend) -> must be excluded, proving the dependency filter works.
    assert_equal ["rallyd"], plan[:consumers]
    refute_includes plan[:consumers], "acumen-ui"
  end

  def test_consumer_target_not_in_graph_yields_empty_plan
    target = Target.new(name: "no-api", stack: :sveltekit)
    plan = codegen_run_plan(target, build)
    assert_empty plan[:backends]
    assert_empty plan[:consumers]
    assert_empty plan[:run_names]
  end
end
