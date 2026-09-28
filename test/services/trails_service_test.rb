require "test_helper"

class TrailsServiceTest < ActiveSupport::TestCase
  class FakeTransit
    attr_reader :calls, :arrival_times

    def initialize(durations, location: FakeTransit.location_in("America/Los_Angeles"))
      @durations, @location, @calls, @arrival_times = durations, location, [], []
    end

    def self.location_in(time_zone)
      TransitousService::Location.new(latitude: 47, longitude: -122, name: "Seattle", time_zone: time_zone)
    end

    def geocode(origin)
      @location
    end

    def transit_duration(origin:, destination:, arrival_time:)
      @calls << destination
      @arrival_times << arrival_time
      @durations.fetch(destination.name)
    end
  end

  class FakeHiking
    attr_reader :arguments

    def initialize(trails)
      @trails = trails
    end

    def get_trails(**arguments)
      @arguments = arguments
      @trails
    end
  end

  # It is 05:00 PDT on September 22.
  setup { travel_to Time.utc(2026, 9, 22, 12) }
  teardown { travel_back }

  def trail(name)
    OverpassService::Trail.new(name: name, latitude: 47.1, longitude: -122.1)
  end

  def search(transit:, hiking: FakeHiking.new([]), arrival: [2026, 9, 23, 12, 30])
    TrailsService.search(origin: "A & B / 東京", arrival: arrival, maximum_length: 3, transit: transit, hiking: hiking)
  end

  test "sorts transit durations when every route is reachable without destructive selection nil" do
    transit = FakeTransit.new({ "slow" => 900, "fast" => 100 })
    hiking = FakeHiking.new([trail("slow"), trail("fast")])
    result = search(transit: transit, hiking: hiking)
    assert_equal %w[fast slow], result.trails.map(&:name)
    assert_equal "Seattle", result.location.name
    assert_equal({ lat: 47, lon: -122, maximum_length: 3 }, hiking.arguments)
    assert_equal "A & B / 東京", result.trails.first.origin
  end

  test "filters unreachable routes and returns empty arrays consistently" do
    transit = FakeTransit.new({ "reachable" => 600, "unreachable" => nil })
    assert_equal ["reachable"], search(transit: transit, hiking: FakeHiking.new([trail("unreachable"), trail("reachable")])).trails.map(&:name)
    assert_empty search(transit: transit, hiking: FakeHiking.new([trail("unreachable")])).trails
    assert_empty search(transit: transit, hiking: FakeHiking.new([])).trails
  end

  test "missing geocode is actionable validation failure" do
    transit = FakeTransit.new({}, location: nil)
    hiking = FakeHiking.new([])
    assert_raises(SearchErrors::InvalidInput) { search(transit: transit, hiking: hiking) }
    assert_nil hiking.arguments
    assert_empty transit.calls
  end

  test "never performs more than ten transit calls" do
    trails = (1..30).map { |index| trail(index.to_s) }
    transit = FakeTransit.new(trails.to_h { |item| [item.name, 600] })
    assert_equal 10, search(transit: transit, hiking: FakeHiking.new(trails)).trails.length
    assert_equal 10, transit.calls.size
  end

  test "reads the arrival time on the clock at the origin" do
    transit = FakeTransit.new({ "loop" => 600 })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")]))
    assert_equal Time.utc(2026, 9, 23, 19, 30), result.arrival_time
    assert_equal "PDT", result.arrival_time.zone
    assert_equal [Time.utc(2026, 9, 23, 19, 30)], transit.arrival_times
  end

  test "falls back to UTC when the origin's time zone is unknown" do
    [nil, "Not/AZone"].each do |time_zone|
      result = search(transit: FakeTransit.new({}, location: FakeTransit.location_in(time_zone)))
      assert_equal Time.utc(2026, 9, 23, 12, 30), result.arrival_time
      assert_equal "UTC", result.arrival_time.zone
    end
  end

  test "accepts arrivals from now until seven days ahead" do
    transit = FakeTransit.new({})
    [[2026, 9, 22, 5, 1], [2026, 9, 29, 5, 0]].each do |arrival|
      assert_empty search(transit: transit, arrival: arrival).trails
    end
    [[2026, 9, 22, 5, 0], [2026, 9, 29, 5, 1]].each do |arrival|
      hiking = FakeHiking.new([])
      error = assert_raises(SearchErrors::InvalidInput) { search(transit: transit, hiking: hiking, arrival: arrival) }
      assert_includes error.message, "(PDT)"
      assert_nil hiking.arguments
    end
  end
end
