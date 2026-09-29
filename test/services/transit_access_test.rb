require "test_helper"

class TransitAccessTest < ActiveSupport::TestCase
  ORIGIN = [47.0, -122.0].freeze

  # Walking minutes for straight-line meters, as TransitAccess estimates them.
  def walk(meters)
    meters * TransitAccess::DETOUR / TransitAccess::WALK_METERS_PER_MINUTE
  end

  def north(meters)
    meters / 110_574.0
  end

  def access(*stops)
    TransitAccess.new(*ORIGIN, stops)
  end

  test "reaching a box means riding to a stop and walking to its nearest edge" do
    stops = access([47.1, -122.0, 30, 1], [47.2, -122.0, 10, 1])
    box = [47.1 + north(500), -122.01, 47.11, -121.99]
    assert_in_delta 30 + walk(500), stops.reach(box), 0.01
    assert_equal 30, stops.reach([47.09, -122.01, 47.11, -121.99])
  end

  test "walking the whole way counts for up to half an hour, as far as the planner walks" do
    stops = access([47.1, -122.0, 45, 1])
    assert_in_delta walk(1_000), stops.reach([47.0 + north(1_000), -122.0, 47.01 + north(1_000), -122.0]), 0.01
    assert_nil access.reach([47.0 + north(3_000), -122.0, 47.01 + north(3_000), -122.0])
    assert_nil access.reach([47.2, -122.0, 47.21, -122.0])
  end

  test "routes are not joined by walks longer than the planner makes" do
    near_end, far_end = [47.0 + north(2_500), -122.0], [47.0 + north(5_000), -122.0]
    stops = access([47.0 + north(5_500), -122.0, 35, 1])
    assert_equal far_end, stops.access_point([[near_end, far_end]])
    assert_in_delta 35 + walk(500), stops.reach([near_end.first, -122.0, far_end.first, -122.0]), 0.01
  end

  test "stops beyond a half-hour walk and trips over four hours do not count" do
    too_far = north(TransitAccess::WALK_METERS + 50)
    assert_nil access([47.3, -122.0, 20, 1]).reach([47.3 + too_far, -122.0, 47.31 + too_far, -122.0])
    assert_nil access([47.3, -122.0, 235, 2]).reach([47.3 + north(1_000), -122.0, 47.31, -122.0])
    assert_in_delta 210 + walk(1_000), access([47.3, -122.0, 210, 2]).reach([47.3 + north(1_000), -122.0, 47.31, -122.0]), 0.01
  end

  test "the quickest stop wins, even across grid cells" do
    stops = access([47.0395, -122.0, 50, 2], [47.0405, -122.0, 20, 1], [47.2, -122.0, 5, 0])
    assert_in_delta 20 + walk(111.2), stops.reach([47.0415, -122.001, 47.05, -121.999]), 0.1
  end

  test "routes are joined at the point transit reaches soonest" do
    path = [[[47.1, -122.0], [47.105, -122.0]], [[47.105, -122.0], [47.12, -122.0]]]
    stops = access([47.1, -122.003, 60, 1], [47.12, -122.003, 25, 2])
    assert_equal [47.12, -122.0], stops.access_point(path)
    assert_nil access([47.5, -122.0, 10, 0]).access_point(path)
  end
end
