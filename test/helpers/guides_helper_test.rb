require "test_helper"

class GuidesHelperTest < ActionView::TestCase
  Hike = Struct.new(:there)

  def hike(*rides)
    Hike.new({ legs: rides })
  end

  def ride(mode, name, to_name, minutes)
    { mode: mode, name: name, to_name: to_name, departure: "2026-10-10T12:00:00Z", arrival: (Time.utc(2026, 10, 10, 12) + minutes.minutes).iso8601 }
  end

  test "a hike's main ride is its longest train ride, or where no train goes, its longest ride" do
    assert_equal "Hudson train to Breakneck Ridge", main_ride(hike(ride("SUBWAY", "7", "Grand Central", 10),
      ride("REGIONAL_RAIL", "Hudson", "Breakneck Ridge", 70), ride("BUS", "86", "Garrison", 90)))
    assert_equal "554 bus to Issaquah", main_ride(hike(ride("TRAM", "1 Line", "International District", 5), ride("BUS", "554", "Issaquah", 35)))
    assert_equal "Ferry to Bainbridge Island", main_ride(hike(ride("FERRY", nil, "Bainbridge Island", 35)))
    assert_nil main_ride(Hike.new(nil))
  end
end
