#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'
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

# The sweep's working dir is a contract with two other pieces of the system, so
# both halves are pinned here rather than left to a comment.
class TestCodegenWorkdir < Minitest::Test
  RUN_ID = "20260804-153000".freeze

  # bin/api's sibling_spec_paths only treats sibling clones' specs as
  # authoritative under `~/code/ai/<dir>/<repo>`. Clone the sweep anywhere else
  # and every backend spec a consumer needs resolves from the registry — which
  # means RELEASED — so the sweep would regenerate consumers against last
  # released specs and open PRs walking their clients backwards. This layout is
  # the whole reason consumers see main. (See test_api_hermetic.rb for the
  # matching assertion on the bin/api side.)
  def test_workdir_is_a_feature_dir_under_code_ai
    clone = File.join(codegen_workdir(RUN_ID), "platform")
    # The exact walk sibling_spec_paths does from a clone: dirname twice, and the
    # result must be named "ai".
    assert_equal "ai", File.basename(File.dirname(File.dirname(clone)))
    assert_equal File.expand_path("~/code/ai"), File.dirname(File.dirname(clone))
  end

  # macOS caps unix-socket paths at 104 bytes and the sweep runs sbt (whose
  # server socket lives at <feature>/<repo>/project/.sbtboot/server/<hash>/sock)
  # in every scala clone, so the dir name gets the same <=19 char budget every
  # feature dir has.
  def test_workdir_name_fits_the_socket_path_budget
    assert_operator File.basename(codegen_workdir(RUN_ID)).length, :<=, 19
  end

  # One run_id drives both, so a dir and a branch from the same sweep are
  # recognizably a pair.
  def test_workdir_and_branch_share_the_run_id
    assert_includes File.basename(codegen_workdir(RUN_ID)), RUN_ID
    assert_includes "#{CODEGEN_BRANCH_PREFIX}-#{RUN_ID}", RUN_ID
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

  # A nested codegen root is a real consumer: hackathon's playwright/ root is the
  # only reader of playwright-vote, so the graph must see apps only it names.
  def test_load_includes_apps_from_nested_configs
    cfg = Codegen::ApiConfig.load(File.expand_path('fixtures/nested', __dir__))
    assert_equal ["platform", "playwright-vote"], cfg.app_names.to_a.sort
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

  # The real platform noise: timestamp comment change + the generator omitting
  # the trailing newline, so the last line shows -}/+} (identical) with a
  # `\\ No newline at end of file` marker.
  NEWLINE_DIFF = <<~DIFF
    --- a/x.scala
    +++ b/x.scala
    @@ -1,6 +1,6 @@
     /**
       * Generated by API Builder
    -  * Service version: 2026-05-13T10:31:37.560-04:00
    +  * Service version: 2026-07-06T20:10:20.166Z
       */
    @@ -62,4 +62,4 @@
       case ApiResult.Unexpected => unexpectedApiResult(r)
       }
    -}
    +}
    \\ No newline at end of file
  DIFF

  def test_noise_only_diff_true_for_timestamp
    assert Codegen::Sync.noise_only_diff?(TIMESTAMP_DIFF)
  end

  def test_noise_only_diff_true_for_timestamp_plus_trailing_newline
    assert Codegen::Sync.noise_only_diff?(NEWLINE_DIFF)
  end

  def test_noise_only_diff_false_for_code_change
    refute Codegen::Sync.noise_only_diff?(CODE_DIFF)
  end

  def test_noise_only_diff_false_for_added_line
    added = "--- a/r\n+++ b/r\n@@ -1,2 +1,3 @@\n GET /a x\n GET /b y\n+GET /new z\n"
    refute Codegen::Sync.noise_only_diff?(added)
  end

  def test_noise_only_diff_false_for_empty
    refute Codegen::Sync.noise_only_diff?("")
  end

  def test_noise_only_diff_handles_routes_and_elm_comments
    routes = "--- a/r\n+++ b/r\n@@ -1 +1 @@\n-# Service version: a\n+# Service version: b\n"
    elm = "--- a/e\n+++ b/e\n@@ -1 +1 @@\n--- Service version: a\n+-- Service version: b\n"
    assert Codegen::Sync.noise_only_diff?(routes)
    assert Codegen::Sync.noise_only_diff?(elm)
  end

  def test_codegen_api_dirs_finds_root_and_playwright
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".api"))
      FileUtils.mkdir_p(File.join(dir, "playwright/.api"))
      FileUtils.mkdir_p(File.join(dir, "node_modules/pkg/.api"))
      File.write(File.join(dir, ".api/config.pkl"), "x")
      File.write(File.join(dir, "playwright/.api/config.pkl"), "x")
      File.write(File.join(dir, "node_modules/pkg/.api/config.pkl"), "x") # must be ignored
      dirs = codegen_api_dirs(dir)
      assert_equal [dir, File.join(dir, "playwright")], dirs
    end
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

  # Regression: source code that carries the marker in a STRING LITERAL (not a
  # comment) is hand-written, not generated — platform's GeneratedHeader.scala
  # emits the header and was wiped, breaking the codegen build (PR #1255).
  def test_generated_paths_requires_marker_in_comment_line
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "codegen"))
      File.write(File.join(dir, "codegen/GeneratedHeader.scala"), <<~SCALA)
        package generators

        object GeneratedHeader {
          def apply(prefix: String): String =
            s"$prefix Generated by API Builder - https://www.apibuilder.io"
        }
      SCALA
      # comment-style markers across the generated languages must still match
      File.write(File.join(dir, "a.scala"), "/**\n  * Generated by API Builder\n  */\n")
      File.write(File.join(dir, "b.routes"), "# Generated by API Builder\nGET /x\n")
      File.write(File.join(dir, "c.elm"), "-- Generated by API Builder\nmodule C exposing (..)\n")

      paths = Codegen::Sync.generated_paths(dir)

      refute_includes paths, File.join(dir, "codegen/GeneratedHeader.scala")
      assert_includes paths, File.join(dir, "a.scala")
      assert_includes paths, File.join(dir, "b.routes")
      assert_includes paths, File.join(dir, "c.elm")
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
    p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "codegen-sync-x",
                                 verify_cmd: "npm run check", regen_only: false,
                                 build_error: "TS2322: type mismatch")
    assert_includes p, "rallyd"
    assert_includes p, "codegen-sync-x"
    assert_includes p, "npm run check"
    assert_includes p.downcase, "never edit generated files"
    assert_includes p, "TS2322: type mismatch"
    assert_includes p, "gh pr create"
    assert_includes p.downcase, "do not merge to main"
  end

  # The clone is single-branch, so gh cannot resolve the pushed branch without
  # an explicit --head — both prompt variants must include it.
  def test_prompt_pr_create_uses_head_flag
    [true, false].each do |regen_only|
      p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "codegen-sync-x",
                                   verify_cmd: "npm run check", regen_only: regen_only)
      assert_includes p, "--head codegen-sync-x"
    end
  end

  # The slim prompt must forbid the old heavy completion workflow (code-review
  # rounds + rebase) — running it per repo is what made sessions take ~20 min
  # and hang. It should carry the guardrails, not the affirmative instructions.
  def test_prompt_forbids_review_and_rebase
    p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "b",
                                 verify_cmd: "npm run check", regen_only: false)
    assert_includes p.downcase, "do not run code reviews"
    assert_includes p.downcase, "do not rebase"
    refute_includes p.downcase, "code-reviewer agent"
    refute_includes p.downcase, "code-review:code-review"
  end

  def test_regen_only_skips_build
    p = Codegen::Sync.fix_prompt(repo: "rallyd", branch: "b",
                                 verify_cmd: "npm run check", regen_only: true)
    refute_includes p, "npm run check"   # no build step
    refute_includes p.downcase, "code-reviewer agent"
    assert_includes p.downcase, "draft"  # regen-only opens a draft PR
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

# What gets CLONED is a different question from what gets RUN: a repo can be in
# the workdir purely so its specs (backend) or its parsed config (consumer) are
# available to the repos that do run.
class TestCodegenCloneSet < Minitest::Test
  App = Struct.new(:name, :stack, :ignored, keyword_init: true)

  ELIGIBLE = [
    App.new(name: "platform",  stack: :scala,     ignored: false),
    App.new(name: "acumen",    stack: :scala,     ignored: false),
    App.new(name: "rallyd",    stack: :sveltekit, ignored: false),
    App.new(name: "acumen-ui", stack: :elm,       ignored: false),
  ].freeze

  def names(target) = codegen_clone_set(target, ELIGIBLE).map(&:name).sort

  def test_full_sweep_clones_everything
    assert_equal %w[acumen acumen-ui platform rallyd], names(nil)
  end

  # A consumer owns no spec files, so its regen resolves every app from the
  # backend clones beside it in the workdir. Skip the backends and `api` falls
  # back to the registry — released, not merged — and the run rewrites the
  # client backwards. The backends are cloned as spec providers only; they do
  # not run (see codegen_run_plan).
  def test_consumer_target_clones_every_backend_alongside_it
    assert_equal %w[acumen platform rallyd], names(ELIGIBLE.find { |a| a.name == "rallyd" })
  end

  # A backend owns its specs, so it needs no other backend — but every consumer
  # candidate must be cloned for Graph to discover which ones depend on it.
  def test_backend_target_clones_every_consumer_candidate
    assert_equal %w[acumen-ui platform rallyd], names(ELIGIBLE.find { |a| a.name == "platform" })
  end
end

# `dev codegen sync` runs from cron/exec with NO ambient locale, which makes
# Ruby's default external encoding US-ASCII — regex/string ops on non-ASCII
# repo content or subprocess output then raise "invalid byte sequence in
# US-ASCII" (crashed hackathon/properties/rallyd in the 2026-07-15 sweep).
# bin/dev must force UTF-8 itself so behavior never depends on invocation
# environment, and a single malformed byte must be scrubbed, not crash the run.
class TestDevCodegenEncoding < Minitest::Test
  NO_LOCALE = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil }.freeze

  def test_run_step_output_survives_missing_locale_and_malformed_bytes
    script = <<~RUBY
      load #{File.expand_path('../bin/dev', __dir__).inspect}
      _, out = run_step(["cat", ARGV[0]], Dir.pwd, false, +"")
      out =~ /curly/ or raise "expected to match scrubbed output"
      Codegen::Sync.noise_only_diff?(out)
      puts "ENCODING_OK"
    RUBY
    Dir.mktmpdir do |dir|
      fixture = File.join(dir, "smart-quotes.txt")
      # UTF-8 smart quotes plus one genuinely malformed byte (\xFF).
      File.binwrite(fixture, "a \xE2\x80\x9Ccurly\xE2\x80\x9D quote \xFF\n")
      out, status = Open3.capture2e(NO_LOCALE, RbConfig.ruby, "-e", script, fixture)
      assert status.success?, "run_step under empty locale crashed: #{out}"
      assert_includes out, "ENCODING_OK"
    end
  end

  def test_file_read_survives_missing_locale
    script = <<~RUBY
      load #{File.expand_path('../bin/dev', __dir__).inspect}
      File.read(ARGV[0]) =~ /dash/ or raise "expected to match file content"
      puts "ENCODING_OK"
    RUBY
    Dir.mktmpdir do |dir|
      fixture = File.join(dir, "em-dash.txt")
      File.binwrite(fixture, "an em\xE2\x80\x94dash\n")
      out, status = Open3.capture2e(NO_LOCALE, RbConfig.ruby, "-e", script, fixture)
      assert status.success?, "File.read under empty locale crashed: #{out}"
      assert_includes out, "ENCODING_OK"
    end
  end
end
