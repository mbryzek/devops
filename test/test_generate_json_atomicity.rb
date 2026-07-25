#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'tempfile'
require 'shellwords'
load File.expand_path('../lib/common.rb', __dir__)

# `dev deploy` releases several apps in parallel and every devops script rebuilds
# dist/ when it loads a config, so generators and readers of dist/*.config.json run
# concurrently. Before Util.write_atomically, generate-json.rb redirected pkl's
# stdout straight into dist/, truncating a file another process was mid-read of —
# the reader then died with `JSON::ParserError: unexpected token at ''`.
class TestGenerateJsonAtomicity < Minitest::Test
  CONTENT = JSON.generate("app" => { "name" => "properties", "repo_name" => "properties" })

  # A writer that behaves like the old `pkl eval > dist/x.json`: truncate now, fill
  # in slowly. The sleep stands in for pkl's runtime and makes the window the race
  # depended on deterministic rather than timing-dependent.
  def slow_shell_write(path)
    system("(sleep 0.05; cat #{Shellwords.escape(fixture)}) > #{Shellwords.escape(path)}")
  end

  # The "pkl output" the slow writer streams, on disk so the shell command stays
  # free of JSON quoting.
  def fixture
    @fixture ||= begin
      f = Tempfile.new("config")
      f.write(CONTENT)
      f.close
      f.path
    end
  end

  def test_reader_never_sees_a_partial_file
    Dir.mktmpdir do |dir|
      target = File.join(dir, "properties.config.json")
      File.write(target, CONTENT)

      errors = []
      reader = Thread.new do
        60.times do
          begin
            JSON.parse(IO.read(target))
          rescue JSON::ParserError, Errno::ENOENT => e
            errors << e
          end
          sleep 0.005
        end
      end

      writer = Thread.new do
        5.times do
          Util.write_atomically(target) { |tmp| slow_shell_write(tmp) }
        end
      end

      [writer, reader].each(&:join)
      assert_empty errors.map(&:message), "reader observed a partial dist/ file"
      assert_equal CONTENT, IO.read(target)
    end
  end

  # Guards the fix itself: proves the harness above actually catches the bug, so the
  # test can never pass vacuously.
  def test_non_atomic_write_is_what_used_to_break
    Dir.mktmpdir do |dir|
      target = File.join(dir, "properties.config.json")
      File.write(target, CONTENT)

      errors = []
      reader = Thread.new do
        40.times do
          begin
            JSON.parse(IO.read(target))
          rescue JSON::ParserError => e
            errors << e
          end
          sleep 0.005
        end
      end
      writer = Thread.new { 3.times { slow_shell_write(target) } }
      [writer, reader].each(&:join)

      refute_empty errors, "expected the old redirect-into-place write to expose a partial read"
    end
  end

  def test_scratch_file_is_removed_when_the_writer_fails
    Dir.mktmpdir do |dir|
      target = File.join(dir, "properties.config.json")
      File.write(target, CONTENT)

      assert_raises(RuntimeError) do
        Util.write_atomically(target) do |tmp|
          File.write(tmp, "partial")
          raise "pkl blew up"
        end
      end

      assert_equal [File.basename(target)], Dir.children(dir).sort
      assert_equal CONTENT, IO.read(target), "a failed write must leave the old config intact"
    end
  end
end
