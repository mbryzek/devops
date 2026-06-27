#!/usr/bin/env ruby
require 'minitest/autorun'
load File.expand_path('../bin/db-filter-dump', __dir__)

class TestDbFilterDump < Minitest::Test
  # ── parse_predicate: the three documented forms, and rejection of others ──

  def test_parse_predicate_all
    assert_equal({ kind: :all }, parse_predicate('t', 'all'))
  end

  def test_parse_predicate_club
    assert_equal({ kind: :club, col: 'club_id' }, parse_predicate('t', 'club_id in :clubs'))
  end

  def test_parse_predicate_fk_splits_table_and_column
    pred = parse_predicate('t', 'reservation_id in court_reserve.reservations.id')
    assert_equal :fk, pred[:kind]
    assert_equal 'reservation_id', pred[:col]
    assert_equal 'court_reserve.reservations', pred[:ref_table]
    assert_equal 'id', pred[:ref_col]
  end

  def test_parse_predicate_eq
    assert_equal({ kind: :eq, col: 'lower_email', value: 'mbryzek@gmail.com' },
                 parse_predicate('t', 'lower_email = mbryzek@gmail.com'))
  end

  def test_parse_predicate_rejects_unknown_form
    assert_raises(SystemExit) { parse_predicate('t', 'club_id like 5') }
  end

  # ── normalize_entry: plain string vs { where:, blank: } map ──

  def test_normalize_entry_string
    assert_equal({ where: 'all', blank: [] }, normalize_entry('all'))
  end

  def test_normalize_entry_map
    entry = normalize_entry('where' => 'email_id in public.emails.id', 'blank' => ['photo_id', 'mobile_phone_id'])
    assert_equal 'email_id in public.emails.id', entry[:where]
    assert_equal %w[photo_id mobile_phone_id], entry[:blank]
  end

  def test_normalize_entry_map_defaults_where_to_all
    assert_equal({ where: 'all', blank: ['verified_by_user_id'] },
                 normalize_entry('blank' => ['verified_by_user_id']))
  end

  # ── topo_order: referenced tables come before the tables that reference them ──

  def test_topo_order_places_referenced_first
    listed  = %w[child parent]
    fk_refs = { 'child' => ['parent'] }
    order = topo_order(listed, fk_refs)
    assert_operator order.index('parent'), :<, order.index('child')
  end

  def test_topo_order_ignores_self_reference
    order = topo_order(['t'], { 't' => ['t'] })
    assert_equal ['t'], order
  end

  def test_topo_order_ignores_unlisted_references
    order = topo_order(['t'], { 't' => ['not_listed'] })
    assert_equal ['t'], order
  end

  def test_topo_order_breaks_cycles_without_looping
    order = topo_order(%w[a b], { 'a' => ['b'], 'b' => ['a'] })
    assert_equal %w[a b].sort, order.sort
  end

  # ── expand_club_ids: descendants are pulled in, cycles terminate ──

  def test_expand_club_ids_includes_children
    parent = { 'bounce' => nil, 'bounce-malvern' => 'bounce', 'other' => nil }
    assert_equal Set['bounce', 'bounce-malvern'], expand_club_ids(Set['bounce'], parent)
  end

  def test_expand_club_ids_terminates_on_cycle
    parent = { 'a' => 'b', 'b' => 'a' }
    assert_equal Set['a', 'b'], expand_club_ids(Set['a'], parent)
  end

  # ── obfuscate: deterministic, null-safe, format-preserving ──

  def test_obfuscate_is_deterministic
    assert_equal obfuscate(:name, 'Smith'), obfuscate(:name, 'Smith')
  end

  def test_obfuscate_passes_through_nulls
    assert_equal '\N', obfuscate(:name, '\N')
    assert_nil obfuscate(:email, nil)
  end

  def test_obfuscate_email_and_lower_email_agree
    # lower(obfuscated_email) must equal obfuscated_lower_email for the same source
    assert_equal obfuscate(:email, 'User@Example.com'), obfuscate(:lower_email, 'user@example.com')
  end

  def test_obfuscate_phone_is_all_digits
    phone = obfuscate(:phone, 'anything')
    assert_match(/\A\+1\d{10}\z/, phone) # +1 followed by 10 digits = valid US E.164
  end
end
