#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common'
require_relative '../lib/api_config'

class TestApiConfig < Minitest::Test
  FIXTURE = File.expand_path('fixtures/sample_config.pkl', __dir__)

  def setup
    # The fixture uses `spec_glob = "dao/spec/*.json"`, which is resolved
    # relative to Dir.pwd. Use the block form so cwd is restored afterwards
    # and doesn't leak into other tests.
    Dir.chdir(File.dirname(FIXTURE)) do
      @config = ApiConfig.new(FIXTURE)
    end
  end

  def test_orgs
    assert_equal ["bryzek"], @config.orgs
  end

  def test_block_count
    assert_equal 5, @config.blocks.size
  end

  def test_model_only_block
    block = @config.blocks.find { |b| b.applications.map(&:key).include?("apibuilder-spec") }
    gen_keys = block.generators.map(&:key).sort
    assert_equal ["bryzek_play_mock_model", "bryzek_play_model"], gen_keys
  end

  def test_routes_override_applied
    block = @config.blocks.find { |b| b.applications.map(&:key).include?("rallyd-api") }
    routes = block.generators.find { |g| g.key == "bryzek_play_routes" }
    assert_equal "rallyd/conf", routes.target
  end

  def test_filter_attributes_preserved
    block = @config.blocks.find { |b| b.applications.map(&:key) == ["platform"] }
    assert_equal ["user_reference", "person"], block.attributes.dig("filter", "types")
  end

  def test_block_level_attributes_preserved
    block = @config.blocks.find { |b| b.applications.map(&:key) == ["hoa-api"] }
    assert_equal "community_id", block.attributes["http_request_params_global_variable"]
  end

  def test_spec_glob_block
    block = @config.blocks.find { |b| b.group == "dao" }
    refute_nil block
    assert_equal ["psql_scala", "psql_ddl"].sort, block.generators.map(&:key).sort
    # Verifies glob expansion: test/fixtures/dao/spec/dummy.json → Application(key="dummy").
    assert_equal ["dummy"], block.applications.map(&:key)
  end

  # Regression: `dev codegen sync` parses each cloned repo's config from a cwd
  # that is NOT the repo (it runs from wherever `dev` was invoked). A spec_glob
  # must resolve relative to the passed base_dir (the repo), not Dir.pwd — the
  # bug that made the real sweep abort on the acumen/platform `dao` block.
  def test_spec_glob_resolves_relative_to_base_dir_not_cwd
    other = File.expand_path("..", __dir__) # repo root, NOT the fixture dir
    Dir.chdir(other) do
      config = ApiConfig.new(FIXTURE, base_dir: File.dirname(FIXTURE))
      dao = config.blocks.find { |b| b.group == "dao" }
      refute_nil dao
      assert_equal ["dummy"], dao.applications.map(&:key)
    end
  end

  def test_find_target
    assert_equal "generated/app/apibuilder", @config.find_target("apibuilder-spec", "bryzek_play_model")
    assert_equal "rallyd/conf", @config.find_target("rallyd-api", "bryzek_play_routes")
  end

  # Auto-imported transitive deps: app not listed in any block, but the
  # generator key is. Fall back to the first block's target for that generator.
  def test_find_target_falls_back_for_unlisted_app
    assert_equal "./src/generated", @config.find_target("platform-storage", "typescript")
    assert_equal "generated/app/apibuilder", @config.find_target("some-unlisted-app", "bryzek_play_model")
  end

  def test_find_target_returns_nil_when_generator_unknown
    assert_nil @config.find_target("anything", "no_such_generator")
  end

  # Listed apps don't fall back: if the user listed an app under a specific
  # generator set, asking for a different generator should return nil rather
  # than picking up an unrelated block's target — that would mask config errors.
  def test_find_target_does_not_fall_back_for_listed_app_missing_generator
    assert_nil @config.find_target("apibuilder-spec", "typescript")
  end

  # A config that names no nested roots must not grow one, and the reserved
  # output key must never be mistaken for an org.
  def test_nested_configs_defaults_to_empty
    assert_equal [], @config.nested_configs
  end

  NESTED = File.expand_path('fixtures/nested/.api/config.pkl', __dir__)

  def test_nested_configs_are_read
    config = ApiConfig.new(NESTED, base_dir: File.dirname(File.dirname(NESTED)))
    assert_equal ["inner"], config.nested_configs
    assert_equal ["bryzek"], config.orgs
    assert_equal 1, config.blocks.size
    assert_equal ["platform"], config.blocks.first.applications.map(&:key)
  end

  # --- Base config resolution -------------------------------------------------
  #
  # Every repo config amends `modulepath:/api/ApiConfig.pkl`, which the CLI
  # resolves against its OWN devops checkout. These tests pin the two properties
  # that matter: it works with no `devops` next to the repo (the ~/code/ai/
  # workspace case, which used to need a hand-made symlink), and it fails
  # non-zero rather than yielding an empty config when it cannot be resolved.

  def test_config_evaluates_with_no_devops_sibling_anywhere
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "some-repo")
      write_config(repo, <<~PKL)
        amends "#{ApiConfig::BASE_MODULE_URI}"

        org = "bryzek"

        applications = new Listing<AppGroup> {
          new { names { "platform-error" }; generators = module.modelOnly() }
        }
      PKL
      refute File.exist?(File.join(dir, "devops")), "fixture must have no devops sibling"

      config = ApiConfig.new(File.join(repo, ".api", "config.pkl"), base_dir: repo)
      assert_equal ["bryzek"], config.orgs
      assert_equal ["platform-error"], config.blocks.flat_map { |b| b.applications.map(&:key) }
    end
  end

  # The silent no-op this whole scheme exists to kill: an unresolvable base config
  # must never look like "a run that generated nothing".
  def test_unresolvable_base_config_exits_non_zero
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "some-repo")
      write_config(repo, %(amends "modulepath:/api/NoSuchBaseConfig.pkl"\n\norg = "bryzek"\n))

      error = assert_raises(SystemExit) do
        capture_io { ApiConfig.new(File.join(repo, ".api", "config.pkl"), base_dir: repo) }
      end
      assert_equal 1, error.status
    end
  end

  # A config left on the old relative `../../devops/...` amends is a hard error with
  # a pointer to the fix, not a mystery "Cannot find module".
  def test_legacy_relative_amends_fails_with_actionable_message
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "some-repo")
      write_config(repo, %(amends "../../devops/api/ApiConfig.pkl"\n\norg = "bryzek"\n))

      _out, err = capture_io do
        assert_raises(SystemExit) { ApiConfig.new(File.join(repo, ".api", "config.pkl"), base_dir: repo) }
      end
      assert_includes err, ApiConfig::BASE_MODULE_URI
    end
  end

  private

  def write_config(repo_dir, contents)
    FileUtils.mkdir_p(File.join(repo_dir, ".api"))
    IO.write(File.join(repo_dir, ".api", "config.pkl"), contents)
  end
end
