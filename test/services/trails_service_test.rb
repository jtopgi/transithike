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
    attr_reader :departures, :planned, :stop_requests

    def initialize(trips: nil, area: { time_zone: "America/Los_Angeles", area: "Seattle, Washington" }, stops: nil)
      @trips, @area, @stops, @departures, @planned, @stop_requests = trips, area, stops, [], [], []
    end

    def area(latitude, longitude)
      raise @area if @area.is_a?(Exception)

      @area
    end

    def reachable_stops(origin:, departure_time:)
      @stop_requests << departure_time
      raise @stops if @stops.is_a?(Exception)

      @stops
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
    attr_reader :arguments, :access

    def initialize(trails, highlights: {})
      @trails, @highlights = trails, highlights
    end

    def candidates(**arguments)
      @arguments = arguments
      raise @trails if @trails.is_a?(Exception)

      [:candidates]
    end

    def trails(candidates, lat:, lon:, access:)
      @access = access
      @trails
    end

    def highlights(trails)
      raise @highlights if @highlights.is_a?(Exception)

      @highlights
    end
  end

  # Areas by route name; a name mapped to an exception fails its lookup.
  class FakeWiki
    attr_reader :lookups

    def initialize(areas = {})
      @areas, @lookups = areas, []
    end

    def nearby_area(latitude, longitude)
      name = latitude.to_s
      @lookups << name
      raise @areas[name] if @areas[name].is_a?(Exception)

      @areas[name]
    end
  end

  # It is 10:02 PDT on September 22.
  setup { travel_to Time.utc(2026, 9, 22, 17, 2) }
  teardown { travel_back }

  # Each trail's midpoint latitude is its name, so fake lookups can tell trails apart.
  def trail(name, length: 2.0, distance: 3.0, **attributes)
    OverpassService::Trail.new(name: name, latitude: 47.1, longitude: -122.1, length: length, distance: distance,
      osm_id: name.hash, path: [[[name, -122.1]]], **attributes)
  end

  def search(origin: "Seattle", places: FakePlaces.new, transit: FakeTransit.new(trips: {}), hiking: FakeHiking.new([]),
    wiki: FakeWiki.new)
    TrailsService.search(origin: origin, places: places, transit: transit, hiking: hiking, wiki: wiki)
  end

  test "looks up a typed place and lists reachable routes, quicker trips first when all else is equal" do
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

  test "transit stops reachable from the origin guide which routes are checked and where they are joined" do
    transit = FakeTransit.new(trips: {}, stops: [[47.1, -122.1, 30, 1]])
    hiking = FakeHiking.new([])
    result = search(transit: transit, hiking: hiking)
    assert_instance_of TransitAccess, hiking.access
    assert_equal [result.departure_time], transit.stop_requests

    [nil, SearchErrors::UpstreamError.new("down"), SearchErrors::ResponseTooLarge.new("dense")].each do |stops|
      hiking = FakeHiking.new([])
      search(transit: FakeTransit.new(trips: {}, stops: stops), hiking: hiking)
      assert_nil hiking.access
    end
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

  test "falls back to planning the nearest routes when the one-request API fails" do
    transit = FakeTransit.new(trips: SearchErrors::UpstreamError.new("changed"))
    trails = (1..17).map { |index| trail("route #{index}", distance: 20 - index) }
    result = search(transit: transit, hiking: FakeHiking.new(trails))
    assert_equal (3..17).map { |index| "route #{index}" }, transit.planned
    assert_equal [1200] * 15, result.trails.map(&:duration)
  end

  test "route provider failures fail the search" do
    assert_raises(SearchErrors::UpstreamError) do
      search(hiking: FakeHiking.new(SearchErrors::UpstreamError.new("Overpass is down")))
    end
  end

  test "highlights, popularity and day-hike lengths rank routes up; paving, generic names and long trips down" do
    base = trail("base", duration: 1800, transfers: 0)
    score = ->(**changes) { TrailsService.score(base.dup.tap { |copy| changes.each { |key, value| copy[key] = value } }) }
    assert_equal 1, score.call

    assert_equal 2, score.call(highlights: [{ kind: "waterfall", name: "Twin Falls" }])
    assert_equal 1.5, score.call(highlights: [{ kind: "peak", name: nil }])
    assert_equal 3, score.call(highlights: [{ kind: "peak", name: "Si" }] * 3)
    assert_in_delta 1.75, score.call(area: { monthly_views: 999 }), 0.01
    assert_equal 1.5, score.call(notable: true)
    assert_equal 0.5, score.call(length: 0.8 + 0.3)
    assert_equal 0, score.call(length: 0.7)
    assert_equal(-0.25, score.call(paved: 0.5))
    assert_equal 0, score.call(name: "Trail 2")
    assert_in_delta 1 - 1.3125 - 0.5, score.call(duration: 9000), 0.001
    assert_in_delta 0.6, score.call(transfers: 2), 0.001
  end

  test "shows the best routes, with the popularity of their areas, varied across areas" do
    trips = {}
    trails = (1..32).map do |index|
      trips["#{index}"] = { duration: 1800 + index * 60, transfers: 0 }
      trail("#{index}")
    end
    wiki = FakeWiki.new("2" => { title: "Big Park", article_url: "https://en.wikipedia.org/wiki/Big_Park", monthly_views: 50_000 },
      "3" => { title: "Big Park", monthly_views: 50_000 }, "4" => { title: "Big Park", monthly_views: 50_000 },
      "5" => SearchErrors::UpstreamError.new("down"))
    hiking = FakeHiking.new(trails, highlights: { trails[5].osm_id => [{ kind: "waterfall", name: "Falls" }] })
    result = search(transit: FakeTransit.new(trips: trips), hiking: hiking, wiki: wiki)

    assert_equal TrailsService::MAX_RESULTS, result.trails.size
    assert_equal TrailsService::MAX_RESULTS, wiki.lookups.size
    assert_equal %w[2 3 6 1 5 7], result.trails.first(6).map(&:name)
    assert_equal "4", result.trails.last.name
    assert_equal({ title: "Big Park", article_url: "https://en.wikipedia.org/wiki/Big_Park", monthly_views: 50_000 },
      result.trails.first.area)
    assert_nil result.trails.find { |trail| trail.name == "5" }.area
    assert_equal [{ kind: "waterfall", name: "Falls" }], result.trails.third.highlights
    rest = result.trails[2..-2].map(&:score)
    assert_equal rest.sort.reverse, rest
  end

  test "routes are shown without highlights when they cannot be looked up" do
    transit = FakeTransit.new(trips: { "loop" => { duration: 600, transfers: 0 } })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")], highlights: SearchErrors::UpstreamError.new("busy")))
    assert_equal [[]], result.trails.map(&:highlights)
  end
end
