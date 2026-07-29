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
