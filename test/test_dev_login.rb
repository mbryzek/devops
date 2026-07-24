#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers credential normalization at the login prompt. The browser login forms
# strip the password before sending it, so the CLI must too - otherwise a
# pasted password with stray whitespace logs in through the browser and fails
# here with an opaque "Incorrect password".
class TestDevLogin < Minitest::Test
  def read(input)
    read_password(StringIO.new(input))
  end

  def test_strips_trailing_whitespace_from_pasted_password
    assert_equal "s3cret", read("s3cret \n")
    assert_equal "s3cret", read("s3cret\t\n")
  end

  def test_strips_leading_whitespace_from_pasted_password
    assert_equal "s3cret", read(" s3cret\n")
  end

  def test_preserves_interior_whitespace
    # Spaces inside a passphrase are part of the credential - only the edges go.
    assert_equal "correct horse battery", read("  correct horse battery \n")
  end

  def test_handles_missing_trailing_newline_and_eof
    assert_equal "s3cret", read("s3cret")
    assert_nil read("")
  end

  def test_all_whitespace_password_reads_as_empty
    # cmd_login treats empty as "skipped (no password)" rather than posting it.
    assert_equal "", read("   \n")
  end
end
