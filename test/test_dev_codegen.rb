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
    refute o[:check]
  end

  def test_parse_codegen_sync_all_flags
    o = parse_codegen_sync_args(%w[--app rallyd --concurrency 2 --dry-run --regen-only --full-tests])
    assert_equal "rallyd", o[:app]
    assert_equal 2, o[:concurrency]
    assert o[:dry_run]
    assert o[:regen_only]
    assert o[:full_tests]
  end

  def test_parse_codegen_sync_check_implies_dry_run
    o = parse_codegen_sync_args(%w[--check])
    assert o[:check]
    assert o[:dry_run], "--check must never open a PR or spawn Claude"
  end

  def test_parse_codegen_sync_rejects_check_with_fix_producing_flags
    assert_raises(SystemExit) { parse_codegen_sync_args(%w[--check --regen-only]) }
    assert_raises(SystemExit) { parse_codegen_sync_args(%w[--check --full-tests]) }
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
    assert_includes p.downcase, "never edit, revert, delete or rename a generated file"
    assert_includes p, "TS2322: type mismatch"
    assert_includes p, "gh pr create"
    assert_includes p.downcase, "do not merge to main"
  end

  # Every shortcut properties#45 took (ISS-630) has to be named in the prompt as
  # well as caught afterwards — a session told only "make it build" reaches for
  # the suppression first, and rejecting the PR afterwards costs a whole sweep.
  def test_prompt_names_every_refused_shortcut
    p = Codegen::Sync.fix_prompt(repo: "properties", branch: "b",
                                 verify_cmd: "npm run check", regen_only: false)
    %w[@ts-nocheck @ts-ignore @ts-expect-error eslint-disable scalastyle:off @nowarn
       tsconfig*.json build.sbt package.json].each do |token|
      assert_includes p, token
    end
    assert_includes p.downcase, "never add a new file beside"
    assert_includes p.downcase, "rebase away the regen commit"
  end

  # The session is handed a committed regen, not a dirty tree — that commit is
  # the base every post-session check diffs against.
  def test_prompt_states_the_regen_is_already_committed
    p = Codegen::Sync.fix_prompt(repo: "properties", branch: "b",
                                 verify_cmd: "npm run check", regen_only: false)
    assert_includes p.downcase, "already committed"
  end

  # Stopping with no PR is an instructed outcome, not only a crash: a repo the
  # sweep cannot fix cleanly belongs at needs_attention, which the playbook
  # handles, rather than in a PR that suppresses the error.
  def test_prompt_tells_the_session_to_stop_rather_than_suppress
    p = Codegen::Sync.fix_prompt(repo: "properties", branch: "b",
                                 verify_cmd: "npm run check", regen_only: false)
    assert_includes p.downcase, "do not open a pr"
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

# The bounded fix session's output is checked, never trusted. Every case below
# is something properties#45 actually did (ISS-630): it reverted the regen,
# prepended `// @ts-nocheck` to three generated files, added a hand-written
# `.d.ts` shim beside them and set `noImplicitAny: false` — and came back as
# `pr_opened`, indistinguishable in the summary from a clean sync.
class TestFixSessionViolations < Minitest::Test
  GENERATED = %w[
    playwright/generated/com-bryzek-platform.ts
    playwright/generated/com-bryzek-properties-api.ts
    src/lib/generated/client.ts
  ].freeze

  def violations(name_status, diff = "")
    Codegen::Sync.fix_session_violations(name_status: name_status, diff_text: diff, generated: GENERATED)
  end

  def diff_adding(path, line)
    "--- a/#{path}\n+++ b/#{path}\n@@ -1,0 +1,1 @@\n+#{line}\n"
  end

  # A session that only fixes consuming code is the whole point — it must pass.
  def test_a_clean_consumer_fix_is_allowed
    diff = "--- a/src/routes/x.svelte\n+++ b/src/routes/x.svelte\n@@ -1 +1 @@\n-old(a)\n+renamed(a)\n"
    assert_empty violations("M\tsrc/routes/x.svelte\n", diff)
  end

  def test_editing_a_generated_file_is_refused
    v = violations("M\tplaywright/generated/com-bryzek-platform.ts\n")
    assert_equal ["edited generated file playwright/generated/com-bryzek-platform.ts"], v
  end

  def test_deleting_a_generated_file_is_refused
    assert_includes violations("D\tsrc/lib/generated/client.ts\n").first, "deleted generated file"
  end

  # Renaming one out of the way is deleting it with extra steps.
  def test_renaming_a_generated_file_is_refused
    v = violations("R100\tsrc/lib/generated/client.ts\tsrc/lib/generated/client.old.ts\n")
    assert_includes v, "deleted generated file src/lib/generated/client.ts"
    assert_includes v, "added src/lib/generated/client.old.ts inside generated directory src/lib/generated"
  end

  # The `.d.ts` re-export shim: a hand-written file the generator does not own,
  # dropped in beside the files it does. The next regen leaves it orphaned.
  def test_a_new_file_in_a_generated_directory_is_refused
    v = violations("A\tplaywright/generated/com-bryzek-properties-api.d.ts\n")
    assert_equal ["added playwright/generated/com-bryzek-properties-api.d.ts " \
                  "inside generated directory playwright/generated"], v
  end

  # Generated directories legitimately hold hand-written files too (platform's
  # api/conf keeps application.conf next to generated *.routes), so only ADDING
  # a file there is refused — editing a hand-written neighbour is real work.
  def test_editing_a_hand_written_neighbour_is_allowed
    assert_empty violations("M\tplaywright/generated/README.md\n")
  end

  # Path-matched, not header-matched: stripping the marker off a generated file
  # before editing it must not buy the session a pass.
  def test_a_generated_file_is_matched_by_path_not_by_its_header
    diff = "--- a/src/lib/generated/client.ts\n+++ b/src/lib/generated/client.ts\n" \
           "@@ -1 +1 @@\n-// Generated by API Builder\n+// hand written, honest\n"
    assert_includes violations("M\tsrc/lib/generated/client.ts\n", diff).first, "edited generated file"
  end

  def test_relaxing_tsconfig_is_refused
    v = violations("M\ttsconfig.playwright.json\n",
                   diff_adding("tsconfig.playwright.json", '    "noImplicitAny": false,'))
    assert_equal ["edited build config tsconfig.playwright.json"], v
  end

  # Weakening the `check` script or ignoring the generated output makes the
  # build go green the same way a compiler flag does.
  def test_package_json_and_gitignore_are_build_config
    assert_includes violations("M\tpackage.json\n").first, "build config package.json"
    assert_includes violations("M\t.gitignore\n").first, "build config .gitignore"
  end

  def test_build_config_matches_every_stack
    %w[tsconfig.json tsconfig.playwright.json .eslintrc .eslintrc.cjs eslint.config.js
       svelte.config.js elm.json review/src/ReviewConfig.elm build.sbt .scalafmt.conf
       scalastyle-config.xml].each do |p|
      assert Codegen::Sync.build_config_path?(p), "expected #{p} to count as build config"
    end
  end

  def test_ordinary_source_is_not_build_config
    %w[src/lib/api.ts config/routes.ts my-package.json.md src/Main.elm].each do |p|
      refute Codegen::Sync.build_config_path?(p), "expected #{p} NOT to count as build config"
    end
  end

  def test_added_suppressions_are_refused
    ["// @ts-nocheck", "// @ts-ignore", "// @ts-expect-error", "/* eslint-disable */",
     "// scalastyle:off", "@nowarn"].each do |line|
      v = violations("M\tsrc/lib/x.ts\n", diff_adding("src/lib/x.ts", line))
      refute_empty v, "expected #{line.inspect} to be refused"
      assert_includes v.first, "added suppression"
    end
  end

  def test_suppression_finding_names_the_file
    v = Codegen::Sync.suppression_findings(diff_adding("src/lib/x.ts", "// @ts-nocheck"))
    assert_equal ["src/lib/x.ts: added suppression `// @ts-nocheck`"], v
  end

  # Only lines the session ADDED count. A suppression already in the repo is
  # somebody else's reviewed decision, and it shows up as context, as a removed
  # line, or in the `---`/`+++` headers — none of which is a finding.
  def test_untouched_and_removed_suppressions_are_not_findings
    diff = "--- a/src/@ts-nocheck-notes.ts\n+++ b/src/@ts-nocheck-notes.ts\n" \
           "@@ -1,3 +1,3 @@\n // @ts-nocheck\n-eslint-disable-me()\n+renamed()\n"
    assert_empty Codegen::Sync.suppression_findings(diff)
  end

  def test_empty_diff_and_empty_name_status_are_clean
    assert_empty violations("", "")
  end

  # One session can take several shortcuts at once, and the summary has to name
  # all of them — a human reading it should not have to re-derive the rest.
  def test_every_shortcut_is_reported_together
    name_status = "M\tplaywright/generated/com-bryzek-platform.ts\n" \
                  "A\tplaywright/generated/com-bryzek-properties-api.d.ts\n" \
                  "M\ttsconfig.playwright.json\n"
    diff = diff_adding("playwright/generated/com-bryzek-platform.ts", "// @ts-nocheck")
    v = violations(name_status, diff)
    assert_equal 4, v.length, v.inspect
    assert(v.any? { |f| f.include?("edited generated file") })
    assert(v.any? { |f| f.include?("inside generated directory") })
    assert(v.any? { |f| f.include?("build config tsconfig.playwright.json") })
    assert(v.any? { |f| f.include?("added suppression") })
  end
end

class TestGeneratedRelativePaths < Minitest::Test
  # git speaks repo-relative paths; the wipe set is absolute. The comparison
  # between them is what catches a hand-edited generated file, so the two forms
  # have to line up exactly.
  def test_paths_are_repo_relative
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "playwright/generated"))
      File.write(File.join(dir, "playwright/generated/a.ts"), "// Generated by API Builder\n")
      File.write(File.join(dir, "handwritten.ts"), "export const x = 1\n")
      assert_equal ["playwright/generated/a.ts"], Codegen::Sync.generated_relative_paths(dir)
    end
  end
end

# `dev codegen sync --check` is the `codegen-sync` producer's check, so these
# exit codes are the producer contract from agent/producers.yml, not local
# detail: 0 nothing to do, 1 file the issue, >1 recorded as check_failed.
class TestCodegenCheckExitCode < Minitest::Test
  def test_clean_when_every_repo_in_sync
    results = { "acumen" => { status: :in_sync }, "rallyd" => { status: :in_sync } }
    assert_equal CODEGEN_EXIT_CLEAN, codegen_check_exit_code(results)
  end

  def test_findings_when_any_repo_changed
    results = { "acumen" => { status: :in_sync }, "rallyd" => { status: :changed } }
    assert_equal CODEGEN_EXIT_FINDINGS, codegen_check_exit_code(results)
  end

  # A demonstrated diff is a real finding even when a sibling repo failed; exit 2
  # would drop it until the next nightly run.
  def test_findings_win_over_a_broken_sibling_repo
    results = { "acumen" => { status: :error, error: "clone failed" }, "rallyd" => { status: :changed } }
    assert_equal CODEGEN_EXIT_FINDINGS, codegen_check_exit_code(results)
  end

  def test_uncheckable_when_a_repo_errored_and_none_drifted
    results = { "acumen" => { status: :in_sync }, "rallyd" => { status: :error, error: "api failed" } }
    assert_equal CODEGEN_EXIT_UNCHECKABLE, codegen_check_exit_code(results)
  end

  def test_uncheckable_when_a_repo_was_skipped
    results = { "acumen" => { status: :in_sync }, "rallyd" => { status: :skipped, error: "dependency failed" } }
    assert_equal CODEGEN_EXIT_UNCHECKABLE, codegen_check_exit_code(results)
  end

  # "Examined nothing" is never evidence that generated code is in sync.
  def test_uncheckable_when_nothing_ran
    assert_equal CODEGEN_EXIT_UNCHECKABLE, codegen_check_exit_code({})
  end

  # Clean requires every repo to have said :in_sync. A status only the
  # PR-opening path can produce means a check mutated something — never "clean".
  def test_uncheckable_on_a_status_a_check_should_not_be_able_to_produce
    assert_equal CODEGEN_EXIT_UNCHECKABLE, codegen_check_exit_code("acumen" => { status: :pr_opened })
    assert_equal CODEGEN_EXIT_UNCHECKABLE, codegen_check_exit_code("acumen" => { status: :needs_attention })
  end

  # The verdict is the filed issue's body, so it must name the repos to resync.
  def test_findings_verdict_names_the_drifted_repos_and_the_fix
    results = { "acumen" => { status: :in_sync }, "rallyd" => { status: :changed }, "hackathon" => { status: :changed } }
    verdict = codegen_check_verdict(results, CODEGEN_EXIT_FINDINGS)
    assert_includes verdict, "rallyd"
    assert_includes verdict, "hackathon"
    refute_includes verdict, "acumen"
    assert_includes verdict, "dev codegen sync"
  end
end

# `cmd_codegen_sync` in check mode, with the sweep itself stubbed: what is under
# test is the translation from a sweep outcome to a process exit code, which no
# amount of unit-testing `codegen_check_exit_code` covers — the sweep aborts by
# calling `exit 1`, and 1 is the one code that must NEVER come out of a broken
# check.
class TestCodegenCheckCommand < Minitest::Test
  include DevTestSupport

  # Replaces the sweep with `body` for the duration of the block. Defined on
  # Object because bin/dev's commands are top-level methods.
  def stub_sweep(body)
    Object.send(:alias_method, :__real_run_codegen_sweep, :run_codegen_sweep)
    Object.send(:define_method, :run_codegen_sweep) { |_opts| body.call }
    yield
  ensure
    Object.send(:alias_method, :run_codegen_sweep, :__real_run_codegen_sweep)
    Object.send(:remove_method, :__real_run_codegen_sweep)
  end

  def run_check(sweep)
    status = nil
    out = nil
    stub_sweep(sweep) do
      out = capture_stdout do
        begin
          cmd_codegen_sync(["--check"])
        rescue SystemExit => e
          status = e.status
        end
      end
    end
    [out, status]
  end

  def test_exits_clean_when_nothing_drifted
    out, status = run_check(-> { { "acumen" => { status: :in_sync } } })
    assert_equal CODEGEN_EXIT_CLEAN, status
    assert_includes out, "in sync"
  end

  def test_exits_findings_when_a_repo_drifted
    out, status = run_check(-> { { "rallyd" => { status: :changed } } })
    assert_equal CODEGEN_EXIT_FINDINGS, status
    assert_includes out, "rallyd"
  end

  # The ISS-359 shape: the sweep aborts (bad --app, unclonable backend, failing
  # git) with `exit 1`. Exit 1 means "file the issue"; a broken check must come
  # back as check_failed instead.
  def test_a_hard_abort_inside_the_sweep_is_uncheckable_not_a_finding
    _out, status = run_check(-> { exit 1 })
    assert_equal CODEGEN_EXIT_UNCHECKABLE, status
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

  # A missing binary is a FAILED STEP, not an exception out of the sweep. Every
  # caller loops over repos and handles a false; none of them handles ENOENT, so
  # one absent tool used to abort mid-loop and discard both the results already
  # collected and the repos not yet reached. It also decides `dev browserslist
  # update --check`'s exit code (ISS-525): an escaping ENOENT left the process at
  # 1, which in the check contract reads "these repos need updating" rather than
  # "nothing was concluded".
  def test_run_step_reports_a_missing_binary_instead_of_raising
    log = +""
    ok, out = run_step(["definitely-not-a-real-binary-i525"], Dir.pwd, false, log)
    refute ok, "a missing binary must come back as a failed step"
    assert_includes out.to_s, "definitely-not-a-real-binary-i525"
    assert_includes log, "definitely-not-a-real-binary-i525",
                    "the reason must reach the captured log the caller reports from"
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

# `verify_fix_session` end to end, against a real git repo with a real remote
# and a stub generator on PATH. The unit tests above pin what counts as a
# violation; this pins that the sweep actually looks — properties#45 (ISS-630)
# was reported `pr_opened` because nothing between "claude printed a PR URL"
# and the summary ever re-established a single property of the branch.
class TestVerifyFixSession < Minitest::Test
  GENERATED_HEADER = "// Generated by API Builder\n".freeze

  def setup
    @dir = Dir.mktmpdir("verify-fix-session")
    @origin = File.join(@dir, "origin.git")
    @clone = File.join(@dir, "repo")
    @bin = File.join(@dir, "bin")
    @branch = "codegen-sync-20260806-000000"
    @pr_url = "https://github.com/mbryzek/properties/pull/45"
    FileUtils.mkdir_p(@bin)
    @saved_path = ENV["PATH"]
    ENV["PATH"] = "#{@bin}:#{@saved_path}"

    # `gh` must never be reached from a test — the only gh call on this path is
    # the draft demotion, and a real one would hit GitHub.
    @demoted = []
    demoted = @demoted
    @orig_demote = method(:demote_pr_to_draft)
    Object.send(:define_method, :demote_pr_to_draft) { |_clone, url| demoted << url }

    build_repo
  end

  def teardown
    ENV["PATH"] = @saved_path
    Object.send(:define_method, :demote_pr_to_draft, @orig_demote)
    FileUtils.remove_entry(@dir)
  end

  # A stub `api`: rewrites the one generated file from `body`, exactly as the
  # real generator would. Changing `body` after the regen commit is how a
  # "the tree is not what the generator produces" case is set up.
  def install_api(body)
    File.write(File.join(@bin, "api"), <<~SH)
      #!/bin/sh
      mkdir -p generated
      printf '%s' '#{GENERATED_HEADER}export const VERSION = "#{body}"
      ' > generated/client.ts
    SH
    FileUtils.chmod(0o755, File.join(@bin, "api"))
  end

  def git(*args, dir: @clone)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
    out
  end

  def build_repo
    Open3.capture2e("git", "init", "--bare", "--initial-branch=main", @origin)
    Open3.capture2e("git", "init", "--initial-branch=main", @clone)
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "test")
    git("remote", "add", "origin", @origin)
    FileUtils.mkdir_p(File.join(@clone, ".api"))
    File.write(File.join(@clone, ".api", "config.pkl"), "// stub\n")
    File.write(File.join(@clone, "app.ts"), "import { VERSION } from './generated/client'\n")
    install_api("v1")
    Open3.capture2e("api", chdir: @clone)
    git("add", "-A")
    git("commit", "-m", "base")
    git("push", "-u", "origin", "main")

    # The sweep's own regen, committed before the session is handed the clone.
    git("checkout", "-b", @branch)
    install_api("v2")
    Open3.capture2e("api", chdir: @clone)
    @generated = Codegen::Sync.generated_relative_paths(@clone)
    @regen_sha, err = commit_regen(@clone)
    raise err if err
  end

  # Everything a session does: edit files, commit, push. `push:` false leaves
  # the remote behind the local tree.
  def session(push: true)
    yield
    git("add", "-A")
    git("commit", "--allow-empty", "-m", "fix consuming code")
    git("push", "-u", "origin", @branch) if push
  end

  def verify(verify_cmd: "true")
    verify_fix_session(@clone, @branch, :sveltekit, verify_cmd,
                       regen_sha: @regen_sha, generated: @generated, pr_url: @pr_url)
  end

  def assert_rejected(result, reason)
    assert_equal :needs_attention, result[:status], result.inspect
    assert_equal @pr_url, result[:pr_url], "the summary must still carry the PR so a human can find it"
    assert_includes result[:error], reason
    assert_equal [@pr_url], @demoted, "a rejected PR must not be left looking ready to merge"
  end

  def test_a_clean_fix_session_is_accepted
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    result = verify
    assert_equal({ status: :pr_opened, pr_url: @pr_url }, result)
    assert_empty @demoted
  end

  # properties#45, exactly: main's pre-regen content with `// @ts-nocheck`
  # prepended, committed over the regeneration.
  def test_reverting_the_regen_with_a_suppression_is_rejected
    session do
      File.write(File.join(@clone, "generated/client.ts"),
                 "// @ts-nocheck\n#{GENERATED_HEADER}export const VERSION = \"v1\"\n")
    end
    result = verify
    assert_rejected(result, "edited generated file generated/client.ts")
    assert_includes result[:error], "added suppression"
  end

  def test_a_shim_in_a_generated_directory_is_rejected
    session { File.write(File.join(@clone, "generated/client.d.ts"), "export * from './client'\n") }
    assert_rejected(verify, "inside generated directory generated")
  end

  def test_relaxing_a_build_config_is_rejected
    session { File.write(File.join(@clone, "tsconfig.json"), "{\"noImplicitAny\": false}\n") }
    assert_rejected(verify, "build config tsconfig.json")
  end

  # The only check that catches a tree the generator disagrees with WITHOUT any
  # forbidden path or token in the diff — and the property the sweep exists to
  # guarantee, so it is asserted rather than inferred from the other checks.
  def test_a_tree_the_generator_would_rewrite_is_rejected
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    install_api("v3")  # the committed tree is no longer what `api` produces
    assert_rejected(verify, "did not survive the fix session")
  end

  def test_a_tree_that_does_not_build_is_rejected
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    assert_rejected(verify(verify_cmd: "false"), "does not build")
  end

  def test_dropping_the_regen_commit_is_rejected
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    git("reset", "--hard", "origin/main")
    git("push", "--force", "-u", "origin", @branch)
    assert_rejected(verify, "no longer in the branch")
  end

  def test_uncommitted_changes_are_rejected
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    File.write(File.join(@clone, "app.ts"), "// and one more thing\n")
    assert_rejected(verify, "left the tree dirty")
  end

  # A session that pushed, opened the PR and then kept committing leaves a PR
  # nothing has checked. What GitHub shows is the remote, not this clone.
  def test_a_remote_that_does_not_match_the_checked_tree_is_rejected
    session { File.write(File.join(@clone, "app.ts"), "// updated caller\n") }
    session(push: false) { File.write(File.join(@clone, "app.ts"), "// unpushed afterthought\n") }
    assert_rejected(verify, "is not the tree these checks ran against")
  end
end

# The diff parser's two ambiguities, pinned: a line of added CONTENT beginning
# `+++ ` must not be read as a file header, and the header itself must not be
# read as an added line.
class TestSuppressionFindingsDiffParsing < Minitest::Test
  def test_added_content_beginning_with_plusplusplus_is_content_not_a_header
    diff = "diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n" \
           "@@ -1,0 +1,2 @@\n+++ not a header\n+// @ts-nocheck\n"
    assert_equal ["src/x.ts: added suppression `// @ts-nocheck`"],
                 Codegen::Sync.suppression_findings(diff)
  end

  def test_a_filename_containing_a_directive_is_not_itself_a_finding
    diff = "diff --git a/src/eslint-disable.md b/src/eslint-disable.md\n" \
           "--- a/src/eslint-disable.md\n+++ b/src/eslint-disable.md\n@@ -1 +1 @@\n-a\n+b\n"
    assert_empty Codegen::Sync.suppression_findings(diff)
  end
end
