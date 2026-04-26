#!/usr/bin/env ruby
require 'minitest/autorun'
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
end
