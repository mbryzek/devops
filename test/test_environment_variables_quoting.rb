#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'open3'
require_relative '../lib/environment_variables'

# `bin/env`'s output is EVAL'D by the caller — `eval "$(bin/env --app platform
# --env development --format sh)"` in bin/run — and the values are the
# git-crypt'd app secrets: passwords, tokens, connection strings.
#
# So the serializations are shell, and the only question that matters is whether
# a value survives a round trip through a real shell byte for byte. It did not:
# `sh` wrapped values in single quotes without escaping an embedded quote, and
# `env` wrapped them in DOUBLE quotes, where the shell still expands $VAR, `cmd`
# and backslashes. A password with a $ in it eval'd to the wrong value silently;
# one with a backtick ran a command.
#
# These assert against `sh` itself rather than against an expected string,
# because the shell is the thing being satisfied and a hand-written expectation
# would just re-implement the bug.
class TestEnvironmentVariablesQuoting < Minitest::Test
  # Values a real secret can contain. Each one breaks a different naive quoting.
  HOSTILE = {
    "SINGLE_QUOTE" => "pa'ss",
    "DOUBLE_QUOTE" => 'pa"ss',
    "DOLLAR" => 'p$HOME$(id)ss',
    "BACKTICK" => 'pa`id`ss',
    "BACKSLASH" => 'pa\\ss',
    "SPACES" => "pa ss word",
    "SEMICOLON" => "pa; echo pwned; ss",
    "MIXED" => %q(it's a "$mess" `here`),
  }.freeze

  def vars = EnvironmentVariables.new(HOSTILE.dup)

  # Read the variables back out of a shell that eval'd the serialization, and
  # compare to what went in. `/usr/bin/env -0` so values containing newlines or spaces
  # survive the comparison intact.
  def round_trip(script)
    out, err, status = Open3.capture3("/bin/sh", "-c", "#{script}\n/usr/bin/env -0")
    assert status.success?, "shell rejected the serialization: #{err}"
    out.split("\0").filter_map { |l| l.split("=", 2) }.select { |k, _| HOSTILE.key?(k) }.to_h
  end

  def test_sh_format_survives_a_real_shell_byte_for_byte
    assert_equal HOSTILE, round_trip("export #{vars.serialize('sh')}")
  end

  def test_env_format_survives_a_real_shell_byte_for_byte
    assert_equal HOSTILE, round_trip(vars.serialize("env"))
  end

  # The injection case stated on its own: a value is DATA, never a command. If
  # quoting breaks, `id` runs and its output lands in the variable instead.
  def test_a_value_containing_a_command_substitution_is_never_executed
    %w[sh env].each do |format|
      script = format == "sh" ? "export #{vars.serialize(format)}" : vars.serialize(format)
      out, _, = Open3.capture3("/bin/sh", "-c", "#{script}\nprintf '%s' \"$BACKTICK\"")
      assert_equal 'pa`id`ss', out, "#{format}: the backtick was executed instead of quoted"
    end
  end

  def test_a_value_containing_a_semicolon_cannot_start_a_new_command
    out, _, = Open3.capture3("/bin/sh", "-c", "export #{vars.serialize('sh')}\nprintf '%s' \"$SEMICOLON\"")
    refute_includes out, "pwned\n"
    assert_equal "pa; echo pwned; ss", out
  end
end
