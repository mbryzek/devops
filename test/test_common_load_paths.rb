#!/usr/bin/env ruby
require 'minitest/autorun'

# Regression guard for lib/common.rb, which every bin/ script loads to pull in
# the rest of lib/. It must work no matter how the caller was invoked:
#
#   ~/code/devops/bin/db     (absolute, the usual PATH invocation)
#   bin/db                   (relative, e.g. from the devops checkout)
#
# `require` resolves a relative path against $LOAD_PATH, not the cwd (only
# `require_relative` is file-relative). So when __FILE__ came in relative,
# common.rb's glob produced "bin/../lib/api_batch_client.rb" and every script
# died with LoadError on the first lib file.
class TestCommonLoadPaths < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # Run ruby in a clean child process rooted at the repo, the way a bin script
  # runs. Returns [combined output, exit status].
  def run_ruby(code)
    out = IO.popen(
      ["ruby", "-e", code],
      :chdir => ROOT,
      :err => [:child, :out],
    ) { |io| io.read }
    [out, $?.exitstatus]
  end

  def assert_loads(path)
    out, status = run_ruby("load #{path.inspect}")
    assert_equal 0, status, "load #{path.inspect} from #{ROOT} failed:\n#{out}"
  end

  def test_loads_via_absolute_path
    assert_loads(File.join(ROOT, "lib", "common.rb"))
  end

  def test_loads_via_relative_path
    assert_loads("lib/common.rb")
  end

  # The exact shape bin scripts produce: `load File.join(DIR, '../lib/common.rb')`
  # where DIR is File.dirname(__FILE__) of a relatively-invoked script.
  def test_loads_via_relative_path_through_bin
    assert_loads("bin/../lib/common.rb")
  end

  # The test-side counterpart, and the reason this file is about load paths
  # rather than about common.rb alone: test/test_helper.rb makes lib/ the load
  # root for the SUITE, so a test can require the one module it exercises
  # instead of loading the whole `dev` CLI to get a load path as a side effect.
  #
  # Pinned here because losing it fails silently. Without it, requiring a lib
  # module directly dies on that module's own `require 'agent/paths'` — before
  # the test file has defined a single test — so the run reports a LoadError
  # rather than a red assertion, and every assertion in the file simply never
  # executes. test_agent_workspace_slug.rb was in exactly that state, unnoticed,
  # until ISS-634.
  def test_test_helper_makes_lib_requirable
    out, status = run_ruby("require './test/test_helper'; require 'agent/workspace'")
    assert_equal 0, status, "test_helper did not make lib/ the load root:\n#{out}"
  end

  # lib/ is the load root, so a subdirectory module resolves by name. bin/dev
  # and the tests that exercise it depend on this.
  def test_makes_lib_subdirectories_requirable
    common = File.join(ROOT, "lib", "common.rb")
    out, status = run_ruby(
      "load #{common.inspect}; require 'codegen/graph'; require 'dependencies/updates'",
    )
    assert_equal 0, status, "requiring a lib subdirectory module failed:\n#{out}"
  end
end
