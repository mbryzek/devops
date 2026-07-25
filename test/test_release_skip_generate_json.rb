#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
load File.expand_path('../lib/common.rb', __dir__)

# `bin/release` passes --skip-generate-json to every child release script so a
# release rebuilds dist/ once rather than once per script. The flag is honored by
# Args.parse, so a script that builds its ReleaseHelper (which loads the app config,
# which regenerates dist/) BEFORE parsing ARGV silently ignores it: release-sveltekit
# parsed args 30 lines too late and release-elm never parsed them at all. Beyond the
# duplicate work, the extra generators are what raced `dev deploy`'s parallel
# releases into reading a half-written dist/*.config.json.
class TestReleaseSkipGenerateJson < Minitest::Test
  BIN = File.expand_path('../bin', __dir__)

  # Run a release script from a directory that is no app checkout. Every script
  # resolves its config first, so it exits almost immediately — but not before it
  # would have regenerated dist/. Returns the combined output.
  def run_release(script, *args)
    Dir.mktmpdir do |dir|
      out, _ = Open3.capture2e("ruby", File.join(BIN, script), *args, chdir: dir)
      out
    end
  end

  def assert_skips_generate_json(script, app)
    out = run_release(script, "--app", app, Config::SKIP_REGENERATE_FLAG)
    refute_includes out, "generate-json",
      "#{script} rebuilt dist/ despite #{Config::SKIP_REGENERATE_FLAG}"
    # Proves the script actually got as far as loading config — i.e. the assertion
    # above is not passing because the script died before it could regenerate.
    assert_includes out, "not found"
  end

  def test_release_sveltekit_honors_the_flag
    assert_skips_generate_json("release-sveltekit", "properties")
  end

  def test_release_elm_honors_the_flag
    assert_skips_generate_json("release-elm", "michaelbryzek")
  end

  def test_release_sveltekit_still_regenerates_without_the_flag
    out = run_release("release-sveltekit", "--app", "properties")
    assert_includes out, "generate-json",
      "a standalone release must still rebuild dist/ from the env pkl sources"
  end
end
