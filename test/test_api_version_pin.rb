#!/usr/bin/env ruby
require 'minitest/autorun'
load File.expand_path('../bin/api', __dir__)

# build_batch_form must stamp a codegen application with a pinned version when the
# lock has one for it, and leave it on latest (no version key) otherwise.
class TestApiVersionPin < Minitest::Test
  FIXTURE = File.expand_path('fixtures/sample_config.pkl', __dir__)

  def config
    Dir.chdir(File.dirname(FIXTURE)) { ApiConfig.new(FIXTURE) }
  end

  def platform_app(form)
    form["applications"].find { |a| a["application_key"] == "platform" }
  end

  def test_codegen_application_pinned_when_lock_has_version
    pins = { VersionLock.key("bryzek", "platform") => "2026-05-28T00:00:00.000Z" }
    form = build_batch_form(config, "bryzek", ["codegen"], ["platform"], nil, "disabled", pins)
    assert_equal "2026-05-28T00:00:00.000Z", platform_app(form)["version"]
  end

  def test_codegen_application_unpinned_when_no_lock_entry
    form = build_batch_form(config, "bryzek", ["codegen"], ["platform"], nil, "disabled", {})
    refute platform_app(form).key?("version")
  end
end
