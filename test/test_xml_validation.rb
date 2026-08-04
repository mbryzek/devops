#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# platform 0.18.84 shipped api/conf/logback.xml with a bare "--" used as an em
# dash inside a comment. That is illegal XML, so logback threw during slf4j
# initialization and Play aborted at ProdServerStart — every platform-web and
# platform-job pod CrashLoopBackOff'd. Nothing upstream noticed: sbt does not
# parse conf XML, the Docker build only copies it, and the failure only became
# visible ~6 minutes into the rollout, after the image was pushed.
#
# These pin the two things that keep that class of bug from coming back: the
# parser actually rejects the shape that shipped, and the build wires the check
# in as a hard failure ahead of the image build.
class TestXmlValidation < Minitest::Test
  include DevTestSupport

  K8S_BUILD = File.read(File.expand_path('../bin/k8s-build', __dir__))

  BAD_COMMENT = <<~XML
    <configuration>
      <!-- a bounce pipeline that matched NOTHING -- and one that works
           look identical -->
      <root level="WARN"/>
    </configuration>
  XML

  GOOD_COMMENT = <<~XML
    <configuration>
      <!-- a bounce pipeline that matched NOTHING, and one that works
           look identical -->
      <root level="WARN"/>
    </configuration>
  XML

  def with_conf(contents, name: "logback.xml")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "conf", name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      yield dir
    end
  end

  def test_double_hyphen_in_a_comment_is_reported
    with_conf(BAD_COMMENT) do |dir|
      errors = XmlValidation.errors_in(XmlValidation.config_files(dir))
      assert_equal 1, errors.size,
                   "A bare '--' inside a comment is the exact shape that took " \
                   "platform-job down for two hours; it must not parse clean."
      assert_match(/logback\.xml/, errors.first,
                   "The error has to name the file — the whole point is telling " \
                   "the operator which config to fix, at build time.")
    end
  end

  def test_well_formed_config_reports_no_errors
    with_conf(GOOD_COMMENT) do |dir|
      assert_empty XmlValidation.errors_in(XmlValidation.config_files(dir))
    end
  end

  def test_every_xml_under_conf_is_checked_not_just_logback
    with_conf(BAD_COMMENT, name: "nested/other.xml") do |dir|
      assert_equal 1, XmlValidation.errors_in(XmlValidation.config_files(dir)).size,
                   "conf/**/*.xml must recurse — logback.xml is not the only XML " \
                   "config a Play app can ship."
    end
  end

  def test_validation_runs_before_the_image_is_built
    validate = K8S_BUILD.index("validate_distribution_xml\n")
    build    = K8S_BUILD.index("build_docker_image\n")
    refute_nil validate, "k8s-build must call validate_distribution_xml"
    refute_nil build
    assert validate < build,
           "Validation has to precede build_docker_image. After the build the " \
           "image exists and push_docker_image sends it to a registry tag that " \
           "never moves again."
  end

  def test_malformed_xml_aborts_the_build
    assert_match(/errors\.empty\?.*\n.*Util\.exit_with_error/, K8S_BUILD,
                 "A malformed config must exit_with_error, not warn — a warning " \
                 "in a quiet release scrolls past and the bad image still ships.")
  end
end
