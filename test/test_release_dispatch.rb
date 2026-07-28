#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

# `bin/release` dispatches on the checkout it is run from: a `-postgresql`
# directory releases the database, a `lib-` directory releases a library, and
# everything else is an app that needs --app. Libraries have no devops app
# config, so before the lib- case existed `release` from ~/code/lib-cipher died
# in generate-json with "Missing required argument(s): app".
class TestReleaseDispatch < Minitest::Test
  BIN = File.expand_path('../bin', __dir__)

  def setup
    @root = Dir.mktmpdir
    @origin = File.join(@root, "origin.git")
    sh "git init -q --bare --initial-branch=main #{@origin}"
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def sh(cmd)
    out = `#{cmd} 2>&1`
    raise "setup command failed: #{cmd}\n#{out}" unless $?.success?
  end

  # A clean checkout on main named `name`, so ReleaseFreshness.ensure! passes and
  # `release` gets as far as choosing which release script to run.
  def checkout(name)
    dir = File.join(@root, name)
    sh "git clone -q #{@origin} #{dir}"
    sh "git -C #{dir} -c user.email=t@t -c user.name=t commit -q --allow-empty -m one"
    sh "git -C #{dir} push -q origin main"
    dir
  end

  # stdin is closed by capture2e, so any script we dispatch to stops at its first
  # prompt (Ask raises on EOF) rather than releasing anything.
  def run_release_from(dir)
    out, _ = Open3.capture2e("ruby", File.join(BIN, "release"), chdir: dir)
    out
  end

  def test_library_checkout_dispatches_to_release_lib
    out = run_release_from(checkout("lib-cipher"))
    assert_includes out, "bin/release-lib",
      "a lib- checkout must release as a library"
    refute_includes out, "Missing required argument(s): app",
      "libraries have no devops app config — release must not ask for --app"
  end

  def test_app_checkout_still_requires_app
    out = run_release_from(checkout("some-app"))
    assert_includes out, "Missing required argument(s): app"
    refute_includes out, "bin/release-lib"
  end
end
