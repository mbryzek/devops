#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'util'

# Covers Util.duration, the compact span formatter shared by the deploy stage renderer and
# `dev queries`.
#
# Each tier drops the unit below it once that unit stops carrying information. The day tier
# is the newest: a query's samples routinely span days, and "168h00m" is not a week anyone
# reads.
class TestUtilDuration < Minitest::Test
  def test_seconds_below_a_minute
    assert_equal "0s", Util.duration(0)
    assert_equal "45s", Util.duration(45)
    assert_equal "59s", Util.duration(59.4)
  end

  def test_minutes_carry_seconds
    assert_equal "1m00s", Util.duration(60)
    assert_equal "2m31s", Util.duration(151)
    assert_equal "59m59s", Util.duration(3599)
  end

  def test_hours_carry_minutes
    assert_equal "1h00m", Util.duration(3600)
    assert_equal "1h04m", Util.duration(3840)
    assert_equal "23h59m", Util.duration((23 * 3600) + (59 * 60))
  end

  def test_days_carry_hours
    assert_equal "1d00h", Util.duration(86_400)
    assert_equal "1d12h", Util.duration(86_400 + (12 * 3600))
    assert_equal "7d00h", Util.duration(7 * 86_400)
  end

  # Each boundary is exclusive on the tier below, so nothing renders as "60m00s" or "24h00m".
  def test_each_boundary_rolls_up_rather_than_saturating
    assert_equal "1m00s", Util.duration(60)
    assert_equal "1h00m", Util.duration(3600)
    assert_equal "1d00h", Util.duration(86_400)
  end
end
