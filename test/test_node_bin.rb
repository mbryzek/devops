#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common'
require_relative 'test_helper'

# NodeBin decides WHICH copy of a build tool a release runs. Getting that wrong is
# silent by construction — the release succeeds, with the wrong minifier or the
# wrong compiler — so the resolution order is asserted rather than assumed.
#
# `uglifyjs` is the case that motivated it: acumen-ui declared `uglifyjs` (a stub
# package that ships no bin) instead of `uglify-js`, so nothing was ever installed
# locally and every release silently minified with whatever global was on PATH.
# On a machine that never had one — every agent runner — the release simply
# refused (ISS-1074).
class TestNodeBin < Minitest::Test
  include DevTestSupport

  # A repo whose node_modules/.bin holds `cmd`, as npm would have installed it.
  def with_local_bin(cmd, mode: 0o755)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "node_modules", ".bin")
      FileUtils.mkdir_p(bin)
      path = File.join(bin, cmd)
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(mode, path)
      yield dir, path
    end
  end

  def test_repo_local_binary_wins_over_a_global_one
    # `ruby` is certainly on PATH, so a bare-command answer here would be the
    # global one — which is exactly the outcome under test.
    with_local_bin("ruby") do |dir, path|
      assert_equal path, NodeBin.resolve("ruby", dir: dir)
    end
  end

  def test_the_local_path_is_absolute
    # release-elm interpolates the result into a shell command that may run from
    # another directory (the minify pipeline, the release dir chdir). A relative
    # "node_modules/.bin/uglifyjs" would resolve against whatever cwd that is.
    with_local_bin("uglifyjs") do |dir, path|
      resolved = NodeBin.resolve("uglifyjs", package: "uglify-js", dir: dir)
      assert_equal path, resolved
      assert File.absolute_path?(resolved), "expected an absolute path, got #{resolved}"
    end
  end

  def test_falls_back_to_the_global_when_the_repo_declares_none
    Dir.mktmpdir do |dir|
      assert_equal "ruby", NodeBin.resolve("ruby", dir: dir)
    end
  end

  # A file that is present but not executable is not a usable binary. npm leaves
  # exactly this behind when an install is interrupted, and treating it as
  # resolved fails later, inside the release, as a confusing "permission denied".
  def test_a_non_executable_file_is_not_treated_as_installed
    with_local_bin("ruby", mode: 0o644) do |dir, _path|
      assert_equal "ruby", NodeBin.resolve("ruby", dir: dir)
    end
  end

  def test_exits_when_the_tool_exists_neither_locally_nor_globally
    Dir.mktmpdir do |dir|
      stderr, status = capture_stderr_and_exit do
        NodeBin.resolve("i1074-no-such-command", dir: dir)
      end
      assert_equal 1, status
      assert_includes stderr, "i1074-no-such-command not found"
    end
  end

  # "Please install uglifyjs" — the old message — sends you to a global install,
  # which is the thing this module exists to stop being the answer. Both remedies
  # get named, repo-local first.
  def test_the_missing_message_names_the_npm_package_and_both_remedies
    msg = NodeBin.missing_message(
      "uglifyjs",
      package: "uglify-js",
      url: "https://github.com/mishoo/UglifyJS",
      dir: "/repo",
    )
    assert_includes msg, "uglifyjs not found"
    # The package name, not the command name: declaring the command name is the
    # bug that put a no-op stub in acumen-ui's package.json for years.
    assert_includes msg, '"uglify-js"'
    assert_includes msg, "/repo/package.json"
    assert_includes msg, "npm install"
    assert_includes msg, "https://github.com/mishoo/UglifyJS"
    assert_operator msg.index("npm install"), :<, msg.index("globally"),
      "the repo-local remedy must be offered before the global one"
  end

  # `missing` is what decides whether a release runs `npm install` at all. It has
  # to answer from node_modules and NOT from PATH: a global uglifyjs is precisely
  # the thing that must stop counting as "installed", or the machine that has one
  # keeps skipping the install and keeps releasing with the unpinned version.
  def test_missing_reports_a_tool_the_repo_has_not_installed
    with_local_bin("elm") do |dir, _path|
      assert_equal ["uglifyjs"], NodeBin.missing(["elm", "uglifyjs"], dir: dir)
    end
  end

  def test_missing_is_empty_once_every_tool_is_installed
    with_local_bin("elm") do |dir, _path|
      FileUtils.touch(File.join(dir, "node_modules", ".bin", "uglifyjs"))
      File.chmod(0o755, File.join(dir, "node_modules", ".bin", "uglifyjs"))
      assert_empty NodeBin.missing(["elm", "uglifyjs"], dir: dir)
    end
  end

  def test_missing_ignores_a_global_install
    # `ruby` is on PATH. If PATH counted, this would come back empty and the
    # release would skip the install that puts the PINNED copy in node_modules.
    Dir.mktmpdir do |dir|
      assert_equal ["ruby"], NodeBin.missing(["ruby"], dir: dir)
    end
  end

  def test_the_missing_message_defaults_the_package_to_the_command
    msg = NodeBin.missing_message("elm", dir: "/repo")
    assert_includes msg, '"elm"'
    refute_includes msg, "()", "an absent url must not leave empty parens"
  end
end
