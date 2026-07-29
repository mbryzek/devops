#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common'
require_relative 'test_helper'

# The image tag is what decides whether a session runs the current platformdb
# image or a stale cached one. It is deliberately NOT the schema tag: the image
# also bakes seed data and the init script, so a seed-only change has to move
# the tag or every local Docker cache keeps serving the old image under the
# unchanged schema tag (that is exactly how a null contact_email survived in
# the template long after the seed was written to fix it).
#
# lib/db_images.rb does not compute the tag — platform-postgresql's
# docker/image-tag.sh does, so there is one definition. These tests pin the
# contract of that shell-out: pass the schema tag through, return the script's
# answer, and fail LOUDLY (never fall back to the bare schema tag) when the
# checkout cannot answer.
class TestDbImagesImageTag < Minitest::Test
  include DevTestSupport

  # A fake platform-postgresql checkout whose docker/image-tag.sh behaves as
  # `body` dictates.
  def with_fake_checkout(body, executable: true)
    Dir.mktmpdir do |dir|
      script = File.join(dir, "docker", "image-tag.sh")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/usr/bin/env bash\n#{body}\n")
      FileUtils.chmod(executable ? 0o755 : 0o644, script)
      yield dir
    end
  end

  def test_returns_the_scripts_answer
    with_fake_checkout('echo "$1-rdeadbeef"') do |dir|
      assert_equal "0.5.18-rdeadbeef", DbImages.image_tag("0.5.18", :dir => dir)
    end
  end

  def test_answer_is_stripped
    with_fake_checkout('printf "  0.5.18-rdeadbeef \n"') do |dir|
      assert_equal "0.5.18-rdeadbeef", DbImages.image_tag("0.5.18", :dir => dir)
    end
  end

  def test_schema_tag_is_passed_through_unmangled
    with_fake_checkout('echo "got:$1"') do |dir|
      assert_equal "got:0.5.18", DbImages.image_tag("0.5.18", :dir => dir)
    end
  end

  # ── loud failures ─────────────────────────────────────────────────────────

  def test_missing_script_exits_with_error
    Dir.mktmpdir do |dir|
      err, status = capture_stderr_and_exit { DbImages.image_tag("0.5.18", :dir => dir) }
      assert_equal 1, status
      assert_match(/image-tag\.sh/, err)
    end
  end

  def test_non_executable_script_exits_with_error
    with_fake_checkout('echo "0.5.18-rdeadbeef"', :executable => false) do |dir|
      err, status = capture_stderr_and_exit { DbImages.image_tag("0.5.18", :dir => dir) }
      assert_equal 1, status
      assert_match(/image-tag\.sh/, err)
    end
  end

  def test_failing_script_exits_with_error_including_its_output
    with_fake_checkout('echo "recipe file not found" >&2; exit 1') do |dir|
      err, status = capture_stderr_and_exit { DbImages.image_tag("0.5.18", :dir => dir) }
      assert_equal 1, status
      assert_match(/recipe file not found/, err)
    end
  end

  def test_silent_empty_answer_exits_with_error
    with_fake_checkout('exit 0') do |dir|
      err, status = capture_stderr_and_exit { DbImages.image_tag("0.5.18", :dir => dir) }
      assert_equal 1, status
      assert_match(/0\.5\.18/, err)
    end
  end
end
