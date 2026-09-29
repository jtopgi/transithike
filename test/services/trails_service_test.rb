require "test_helper"

class TrailsServiceTest < ActiveSupport::TestCase
  class FakePlaces
    attr_reader :queries

    def initialize(place = Place.new(name: "Seattle, Washington", latitude: 47, longitude: -122))
      @place, @queries = place, []
    end

    def geocode(query)
      @queries << query
      @place
    end
  end

  class FakeTransit
    attr_reader :departures, :planned

    def initialize(trips: nil, area: { time_zone: "America/Los_Angeles", area: "Seattle, Washington" })
      @trips, @area, @departures, @planned = trips, area, [], []
    end

    def area(latitude, longitude)
      raise @area if @area.is_a?(Exception)

      @area
    end

    def trips(origin:, destinations:, departure_time:)
      @departures << departure_time
      raise @trips if @trips.is_a?(Exception)

      destinations.map { |destination| @trips.fetch(destination.name) }
    end

    def trip(origin:, destination:, departure_time:)
      @planned << destination.name
      { duration: 1200, transfers: 0 }
    end
  end

  class FakeHiking
    attr_reader :arguments

    def initialize(trails)
      @trails = trails
    end

    def get_trails(**arguments)
      @arguments = arguments
      raise @trails if @trails.is_a?(Exception)

      @trails
    end
  end

  # It is 10:02 PDT on September 22.
  setup { travel_to Time.utc(2026, 9, 22, 17, 2) }
  teardown { travel_back }

  def trail(name)
    OverpassService::Trail.new(name: name, latitude: 47.1, longitude: -122.1, length: 2.0, distance: 3.0)
  end

  def search(origin: "Seattle", places: FakePlaces.new, transit: FakeTransit.new(trips: {}), hiking: FakeHiking.new([]))
    TrailsService.search(origin: origin, places: places, transit: transit, hiking: hiking)
  end

  test "looks up a typed place and lists reachable routes by travel time" do
    places = FakePlaces.new
    transit = FakeTransit.new(trips: { "slow" => { duration: 3000, transfers: 1 }, "fast" => { duration: 1200, transfers: nil }, "far" => nil })
    hiking = FakeHiking.new([trail("slow"), trail("far"), trail("fast")])
    result = search(origin: "A & B / 東京", places: places, transit: transit, hiking: hiking)

    assert_equal ["A & B / 東京"], places.queries
    assert_equal({ lat: 47, lon: -122 }, hiking.arguments)
    assert_equal %w[fast slow], result.trails.map(&:name)
    assert_equal [1200, nil], [result.trails.first.duration, result.trails.first.transfers]
    assert_equal "Seattle, Washington", result.trails.first.origin
    assert_equal "Seattle, Washington", result.area
  end

  test "a chosen place needs no lookup and keeps its name" do
    places = FakePlaces.new
    chosen = Place.new(name: "Pike Place Market", latitude: 47.6, longitude: -122.3)
    result = search(origin: chosen, places: places)
    assert_empty places.queries
    assert_same chosen, result.place
  end

  test "an unknown place is actionable before any route search" do
    hiking = FakeHiking.new([])
    assert_raises(SearchErrors::InvalidInput) { search(places: FakePlaces.new(nil), hiking: hiking) }
    assert_nil hiking.arguments
  end

  test "departs now in the origin's time zone during the day" do
    transit = FakeTransit.new(trips: { "loop" => { duration: 600, transfers: 0 } })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")]))
    assert_equal Time.utc(2026, 9, 22, 17, 15), result.departure_time
    assert_equal "PDT", result.departure_time.zone
    assert_equal [result.departure_time], transit.departures
  end

  test "departure times plan for the next morning after mid-afternoon" do
    zone = "America/Los_Angeles"
    assert_equal Time.utc(2026, 9, 22, 21, 45), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 21, 31))
    assert_equal Time.utc(2026, 9, 23, 15), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 22, 0))
    assert_equal Time.utc(2026, 9, 23, 15), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 23, 11, 0))
    assert_equal Time.utc(2026, 9, 22, 17, 0), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 17, 0, 30))
  end

  test "an unknown time zone falls back to UTC" do
    [nil, "Not/AZone"].each do |zone|
      assert_equal "UTC", TrailsService.departure_time(zone).zone
    end
    result = search(transit: FakeTransit.new(trips: {}, area: { time_zone: nil, area: nil }))
    assert_equal "UTC", result.departure_time.zone
  end

  test "the search goes ahead when the area lookup fails" do
    result = search(transit: FakeTransit.new(trips: {}, area: SearchErrors::UpstreamError.new("down")))
    assert_equal "UTC", result.departure_time.zone
    assert_nil result.area
  end

  test "falls back to planning each route when the one-request API fails" do
    transit = FakeTransit.new(trips: SearchErrors::UpstreamError.new("changed"))
    result = search(transit: transit, hiking: FakeHiking.new([trail("a"), trail("b")]))
    assert_equal %w[a b], transit.planned
    assert_equal [1200, 1200], result.trails.map(&:duration)
  end

  test "route provider failures fail the search" do
    assert_raises(SearchErrors::UpstreamError) do
      search(hiking: FakeHiking.new(SearchErrors::UpstreamError.new("Overpass is down")))
    end
  end
end
