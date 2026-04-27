#!/usr/bin/env ruby
require 'minitest/autorun'
load File.expand_path('../bin/api', __dir__)

class TestApiArgs < Minitest::Test
  # resolve_import_expansion encodes the rule that drives the safety story:
  # subset uploads must NOT auto-expand (would wipe types from sibling apps'
  # generated files), full uploads SHOULD auto-expand (so transitive
  # third-party imports like apibuilder-spec still get codegen'd), and the
  # explicit flag always wins.

  def test_no_flag_no_app_filter_enables_expansion
    assert_equal "enabled", resolve_import_expansion(nil, false)
  end

  def test_no_flag_with_app_filter_disables_expansion
    assert_equal "disabled", resolve_import_expansion(["acumen-view"], false)
  end

  def test_explicit_flag_overrides_app_filter
    assert_equal "enabled", resolve_import_expansion(["acumen-view"], true)
  end

  def test_explicit_flag_redundant_on_full_upload
    assert_equal "enabled", resolve_import_expansion(nil, true)
  end

  def test_parse_batch_args_recognizes_expand_imports_flag
    parsed = parse_batch_args(["--expand-imports", "upload"])
    assert_equal true, parsed[:expand_imports_flag]
    assert_equal ["upload"], parsed[:operations]
  end

  def test_parse_batch_args_defaults_flag_to_false
    parsed = parse_batch_args(["upload"])
    assert_equal false, parsed[:expand_imports_flag]
  end

  def test_parse_batch_args_combines_flag_with_app_filter
    parsed = parse_batch_args(["--app", "acumen-view", "--expand-imports"])
    assert_equal true, parsed[:expand_imports_flag]
    assert_equal ["acumen-view"], parsed[:apps]
  end
end
