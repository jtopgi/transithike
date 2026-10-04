require "test_helper"

class DaylightTest < ActiveSupport::TestCase
  # Sunsets from the US Naval Observatory, to the minute.
  test "sunsets are within two minutes of the Naval Observatory's" do
    {
      [Time.utc(2026, 10, 10, 12), 40.7128, -74.006] => Time.utc(2026, 10, 10, 22, 23),
      [Time.utc(2026, 12, 15, 8), 51.5072, -0.1276] => Time.utc(2026, 12, 15, 15, 52),
      [Time.utc(2026, 6, 20, 6), 47.3769, 8.5417] => Time.utc(2026, 6, 20, 19, 26)
    }.each do |(time, latitude, longitude), sunset|
      assert_in_delta sunset, Daylight.sunset(time, latitude, longitude), 2.minutes
    end
  end

  test "sunsets are to the minute before" do
    assert_equal 0, Daylight.sunset(Time.utc(2026, 10, 10, 12), 40.7128, -74.006).sec
  end

  test "the day is the local one, wherever the time falls in UTC" do
    # 8 AM in Tokyo is 11 PM the day before in UTC.
    assert_equal Date.new(2026, 10, 10), Daylight.sunset(Time.utc(2026, 10, 9, 23), 35.68, 139.77).in_time_zone("Asia/Tokyo").to_date
  end

  test "there's no sunset where the sun doesn't set, and no daylight where it doesn't rise" do
    assert_nil Daylight.sunset(Time.utc(2026, 6, 21, 12), 78.22, 15.65)
    assert_operator Daylight.sunset(Time.utc(2026, 12, 21, 12), 78.22, 15.65), :<=, Time.utc(2026, 12, 21, 0)
  end
end
