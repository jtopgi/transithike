require "test_helper"

class TrailsServiceTest < ActiveSupport::TestCase
  class FakePlaces
    attr_reader :queries

    def initialize(place = Place.new(name: "Seattle, Washington", latitude: 47, longitude: -122))
      @place, @queries = place, []
    end

    def geocode(query, near: nil)
      @queries << [query, near]
      @place
    end
  end

  # Trips there, trips by city transit, and latest returns by route name; a
  # name missing from returns has no way back.
  class FakeTransit
    attr_reader :departures, :planned, :station_requests, :return_requests, :city_requests

    # By default, one station 55 km north of the origin, and no trips by city transit.
    def initialize(trips: {}, city: {}, returns: nil, area: { time_zone: "America/Los_Angeles", area: "Seattle, Washington" },
      stations: [[47.5, -122.0, 60]])
      @trips, @city, @returns, @area, @stations = trips, city, returns, area, stations
      @departures, @planned, @station_requests, @return_requests, @city_requests = [], [], [], [], []
    end

    def area(latitude, longitude)
      raise @area if @area.is_a?(Exception)

      @area
    end

    def rail_stations(origin:, departure_time:)
      @station_requests << departure_time
      raise @stations if @stations.is_a?(Exception)

      @stations
    end

    def trips(origin:, destinations:, departure_time:, modes: nil)
      if modes
        @city_requests << modes
        raise @city if @city.is_a?(Exception)

        return destinations.map { |destination| @city[destination.name] }
      end
      @departures << departure_time
      raise @trips if @trips.is_a?(Exception)

      destinations.map { |destination| @trips.fetch(destination.name) }
    end

    def trip(origin:, destination:, departure_time:)
      @planned << destination.name
      { duration: 1200, transfers: 0 }
    end

    # Without returns, every route has a way back at 9 PM.
    def latest_returns(origin:, destinations:, deadline:, earliest_return:)
      @return_requests << [deadline, earliest_return]
      raise @returns if @returns.is_a?(Exception)

      destinations.map { |destination| @returns ? @returns[destination.name] : deadline - 2.hours }
    end
  end

  # Routes by id, in the first tiles or the others. A batch holding a failing
  # route's id fails, and with a release event, stuck lookups wait for it.
  class FakeHiking
    FIRST_TILE = [47.5, -122.5].freeze

    attr_reader :access, :batches, :stations, :tile_requests, :threads

    # stuck names the lookups that wait for release: :first_tiles, :other_tiles, :trails_for, or :highlights.
    def initialize(trails, far: [], highlights: {}, failing: [], release: nil, stuck: [:highlights])
      @trails, @far, @highlights, @failing, @release, @stuck = trails, far, highlights, failing, release, stuck
      @batches, @threads, @tile_requests = [], [], Concurrent::Array.new
    end

    # One tile, or five when there are routes in the others.
    def tiles(stations)
      @stations = stations
      (0...(@far.empty? ? 1 : 5)).map { |index| [47.5, -122.5 + index * 0.5] }
    end

    def routes_in(tiles)
      first = tiles.include?(FIRST_TILE)
      @release&.wait(5) if @stuck.include?(first ? :first_tiles : :other_tiles)
      @tile_requests << tiles
      raise @trails if first && @trails.is_a?(Exception)

      (first ? @trails : @far).map { |trail| { id: trail.osm_id } }
    end

    def pick(routes, access:)
      @access = access
      routes.pluck(:id)
    end

    def trails_for(ids, lat:, lon:, access:)
      @release&.wait(5) if @stuck.include?(:trails_for)
      @threads << Thread.current
      @batches << ids
      raise SearchErrors::UpstreamError, "busy" if ids.intersect?(@failing)

      all = (@trails + @far).index_by(&:osm_id)
      ids.map { |id| all.fetch(id).dup }
    end

    def highlights(trails)
      @release&.wait(5) if @stuck.include?(:highlights)
      raise @highlights if @highlights.is_a?(Exception)

      @highlights
    end
  end

  # Areas by the latitude of a trail's midpoint, which is its name; a name mapped
  # to an exception fails its lookup.
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

  # It is 7:02 AM PDT on Tuesday, September 22, so trips are for Saturday the 26th.
  setup { travel_to Time.utc(2026, 9, 22, 14, 2) }
  teardown { travel_back }

  SATURDAY = Time.utc(2026, 9, 26, 15)

  # A 3-mile loop, about 1.5 hours to hike. Its midpoint's latitude is its name,
  # so fake lookups can tell trails apart.
  def trail(name, length: 3.0, distance: 30.0, loop: true, **attributes)
    OverpassService::Trail.new(name: name, latitude: 47.5, longitude: -122.1, length: length, distance: distance,
      osm_id: name.hash, path: [[[name, -122.1]]], loop: loop, paved: 0, **attributes)
  end

  def search(origin: "Seattle", day: nil, near: nil, places: FakePlaces.new, transit: FakeTransit.new,
    hiking: FakeHiking.new([]), wiki: FakeWiki.new, &block)
    TrailsService.search(origin: origin, day: day, near: near, places: places, transit: transit, hiking: hiking,
      wiki: wiki, &block)
  end

  def minutes(count)
    { duration: count * 60, transfers: 0 }
  end

  test "looks up a typed place near the visitor and lists the routes with a trip there and back, best first" do
    places = FakePlaces.new
    transit = FakeTransit.new(trips: { "slow" => { duration: 3000, transfers: 1 }, "fast" => { duration: 1200, transfers: nil },
      "far" => nil })
    hiking = FakeHiking.new([trail("slow"), trail("far"), trail("fast")])
    result = search(origin: "A & B / 東京", near: [40.7, -74.0], places: places, transit: transit, hiking: hiking)

    assert_equal [["A & B / 東京", [40.7, -74.0]]], places.queries
    assert_equal %w[fast slow], result.trails.map(&:name)
    fast = result.trails.first
    assert_equal [1200, nil, "Seattle, Washington"], [fast.duration, fast.transfers, fast.origin]
    assert_equal SATURDAY + 20.minutes, fast.arrival
    assert_equal Time.utc(2026, 9, 27, 4), fast.last_return
    assert_equal "Seattle, Washington", result.area
    assert result.returns_checked
    assert result.complete
  end

  test "results are reported as they are found: the place, each batch, and the final ranking" do
    trails = (1..5).map { |index| trail("route #{index}") }
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(30)] })
    events = []
    result = stub_const(TrailsService, :BATCH_SIZE, 2) do
      search(transit: transit, hiking: FakeHiking.new(trails)) { |event, payload| events << [event, payload] }
    end

    assert_equal [:place, :checking, :trails, :checking, :trails, :checking, :trails, :ranking, :update], events.map(&:first)
    assert_equal 5, events[-2].last
    place = events.first.last
    assert_equal [SATURDAY, Time.utc(2026, 9, 27, 6)], [place.departure_time, place.return_by]
    assert_equal [2, 2, 1], events.select { |event, _| event == :checking }.map(&:last)
    assert_equal [["route 1", "route 2"], ["route 3", "route 4"], ["route 5"]],
      events.select { |event, _| event == :trails }.map { |_, found| found.map(&:name) }
    assert_equal result.trails, events.last.last
    assert events.select { |event, _| event == :trails }.flat_map(&:last).all?(&:score)
  end

  test "the first batch is from the tiles with the quickest stations, and routes in the others follow" do
    nearby = (1..3).map { |index| trail("near #{index}") }
    farther = [trail("far 1")]
    transit = FakeTransit.new(trips: (nearby + farther).to_h { |trail| [trail.name, minutes(40)] })
    hiking = FakeHiking.new(nearby, far: farther)
    result = stub_const(TrailsService, :BATCH_SIZE, 2) { search(transit: transit, hiking: hiking) }

    assert_instance_of TransitAccess, hiking.access
    assert_equal [[47.5, -122.0, 60]], hiking.stations
    assert_equal [1, 4], hiking.tile_requests.map(&:size).sort
    assert_equal [nearby.first(2), [nearby.last, farther.first]].map { |batch| batch.map(&:osm_id) }, hiking.batches
    assert_equal ["near 1", "near 2", "near 3", "far 1"].sort, result.trails.map(&:name).sort
  end

  test "stations in or next to the city don't count, and without others no routes are looked for" do
    # 10 and 30 km north of the origin.
    transit = FakeTransit.new(trips: { "a" => minutes(30) }, stations: [[47.09, -122.0, 20], [47.27, -122.0, 50]])
    hiking = FakeHiking.new([trail("a")])
    assert_equal ["a"], search(transit: transit, hiking: hiking).trails.map(&:name)
    assert_equal [[47.27, -122.0, 50]], hiking.stations

    hiking = FakeHiking.new([trail("a")])
    events = []
    result = search(transit: FakeTransit.new(stations: [[47.09, -122.0, 20]]), hiking: hiking) { |event, _| events << event }
    assert_empty result.trails
    assert_equal [:place], events
    assert_nil hiking.stations
    assert_empty hiking.tile_requests
  end

  test "hikes the subway or light rail reaches are left out, unless that can't be checked" do
    trails = [trail("by train"), trail("by subway")]
    trips = trails.to_h { |trail| [trail.name, minutes(60)] }
    transit = FakeTransit.new(trips: trips, city: { "by subway" => minutes(95) })
    assert_equal ["by train"], search(transit: transit, hiking: FakeHiking.new(trails)).trails.map(&:name)
    assert_equal [TransitousService::CITY_MODES], transit.city_requests
    # Transitous's METRO means suburban trains, which take city dwellers out for the day.
    assert_equal %w[SUBWAY TRAM], TransitousService::CITY_MODES

    transit = FakeTransit.new(trips: trips, city: SearchErrors::UpstreamError.new("down"))
    assert_equal ["by subway", "by train"], search(transit: transit, hiking: FakeHiking.new(trails)).trails.map(&:name).sort
  end

  test "routes without a way back the same day, or without time to hike before it, are left out" do
    trails = [trail("roomy"), trail("stranded"), trail("rushed"), trail("long", length: 10, loop: false)]
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(60)] }, returns: {
      "roomy" => Time.utc(2026, 9, 27, 2), "stranded" => nil,
      # Arriving at 16:00 UTC, there is 1 hour 29 minutes before the last trip back.
      "rushed" => Time.utc(2026, 9, 26, 17, 29),
      # A 20-mile round trip needs the most time required, 4 hours, which is just what's left.
      "long" => Time.utc(2026, 9, 26, 20)
    })
    result = search(transit: transit, hiking: FakeHiking.new(trails))

    assert_equal %w[roomy long], result.trails.map(&:name)
    deadline, earliest = transit.return_requests.sole
    assert_equal [Time.utc(2026, 9, 27, 6), SATURDAY + 90.minutes], [deadline, earliest]
    assert_equal 1.5, TrailsService.hike_hours(trail("short", length: 1.2))
    assert_equal 7, TrailsService.hike_hours(trail("epic", length: 30))
    assert_equal 5, TrailsService.hike_hours(trail("there and back", length: 5, loop: false))
    assert_equal 4, TrailsService.required_hours(trail("there and back", length: 5, loop: false))
  end

  test "when the way back can't be looked up, routes transit reaches are shown and the result says so" do
    transit = FakeTransit.new(trips: { "a" => minutes(30) }, returns: SearchErrors::UpstreamError.new("changed"))
    result = search(transit: transit, hiking: FakeHiking.new([trail("a")]))
    assert_equal ["a"], result.trails.map(&:name)
    assert_nil result.trails.first.last_return
    refute result.returns_checked
  end

  test "a failed batch is skipped, but a search that finds nothing fails" do
    good, bad = trail("good"), trail("bad")
    transit = FakeTransit.new(trips: { "good" => minutes(30), "bad" => minutes(30) })
    result = stub_const(TrailsService, :BATCH_SIZE, 1) do
      search(transit: transit, hiking: FakeHiking.new([bad, good], failing: [bad.osm_id]))
    end
    assert_equal ["good"], result.trails.map(&:name)
    refute result.complete

    assert_raises(SearchErrors::UpstreamError) do
      search(transit: transit, hiking: FakeHiking.new([bad], failing: [bad.osm_id]))
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
    transit = FakeTransit.new
    assert_raises(SearchErrors::InvalidInput) { search(places: FakePlaces.new(nil), transit: transit, hiking: hiking) }
    assert_empty transit.station_requests
    assert_empty hiking.tile_requests
  end

  test "trips set out at 8 AM on the next weekend day, or the one chosen, in the origin's time zone" do
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")]))
    assert_equal SATURDAY, result.departure_time
    assert_equal "PDT", result.departure_time.zone
    assert_equal [SATURDAY], transit.departures
    assert_equal [SATURDAY], transit.station_requests

    sunday = search(day: "sunday", transit: FakeTransit.new(trips: { "loop" => minutes(10) }), hiking: FakeHiking.new([trail("loop")]))
    assert_equal SATURDAY + 1.day, sunday.departure_time
  end

  test "on the morning of the trip it sets out now, and from 10 AM, the trip is a week later" do
    departs = ->(now, day = nil) { TrailsService.departure_time("America/Los_Angeles", day: day, now: now) }
    # Saturday at 7 AM, 8:31 AM, 9:59:30 AM, and 10 AM.
    assert_equal SATURDAY, departs.(Time.utc(2026, 9, 26, 14))
    assert_equal SATURDAY + 45.minutes, departs.(Time.utc(2026, 9, 26, 15, 31))
    assert_equal SATURDAY + 2.hours, departs.(Time.utc(2026, 9, 26, 16, 59, 30))
    assert_equal SATURDAY + 1.day, departs.(Time.utc(2026, 9, 26, 17))
    assert_equal SATURDAY + 7.days, departs.(Time.utc(2026, 9, 26, 17), "saturday")
    # Sunday at 11 AM, and Friday just before midnight.
    assert_equal SATURDAY + 7.days, departs.(Time.utc(2026, 9, 27, 18))
    assert_equal SATURDAY + 8.days, departs.(Time.utc(2026, 9, 27, 18), "sunday")
    assert_equal SATURDAY, departs.(Time.utc(2026, 9, 26, 6, 59))
    assert_equal Date.new(2026, 9, 27), TrailsService.trip_date(Time.utc(2026, 9, 22).in_time_zone("UTC"), "sunday")
  end

  test "an unknown time zone falls back to UTC" do
    [nil, "Not/AZone"].each do |zone|
      assert_equal "UTC", TrailsService.departure_time(zone).zone
    end
    result = search(transit: FakeTransit.new(area: { time_zone: nil, area: nil }))
    assert_equal "UTC", result.departure_time.zone
  end

  test "the search goes ahead when the area lookup fails" do
    result = search(transit: FakeTransit.new(area: SearchErrors::UpstreamError.new("down")))
    assert_equal "UTC", result.departure_time.zone
    assert_nil result.area
  end

  test "falls back to planning at most 15 of the nearest routes when the one-request API fails" do
    transit = FakeTransit.new(trips: SearchErrors::UpstreamError.new("changed"))
    trails = (1..20).map { |index| trail("route #{index}", distance: 30 - index) }
    result = stub_const(TrailsService, :BATCH_SIZE, 10) { search(transit: transit, hiking: FakeHiking.new(trails)) }
    assert_equal ((1..10).map { |index| "route #{index}" } + (16..20).map { |index| "route #{index}" }).sort, transit.planned.sort
    assert_equal 15, result.trails.size
  end

  test "rail station and route provider failures fail the search" do
    assert_raises(SearchErrors::UpstreamError) do
      search(transit: FakeTransit.new(stations: SearchErrors::UpstreamError.new("Transitous is down")))
    end
    assert_raises(SearchErrors::UpstreamError) do
      search(hiking: FakeHiking.new(SearchErrors::UpstreamError.new("Overpass is down")))
    end
  end

  test "highlights, popularity, day-hike lengths and time there rank routes up; paving, generic names and long trips down" do
    base = trail("base", length: 5, duration: 3600, transfers: 0, arrival: SATURDAY + 1.hour,
      last_return: Time.utc(2026, 9, 27, 2))
    score = ->(**changes) { TrailsService.score(base.dup.tap { |copy| changes.each { |key, value| copy[key] = value } }) }
    assert_equal 1.5, score.call

    assert_equal 2.5, score.call(highlights: [{ kind: "waterfall", name: "Twin Falls" }])
    assert_equal 2, score.call(highlights: [{ kind: "peak", name: nil }])
    assert_equal 3.5, score.call(highlights: [{ kind: "peak", name: "Si" }] * 3)
    assert_in_delta 2.25, score.call(area: { monthly_views: 999 }), 0.01
    assert_equal 2, score.call(notable: true)
    assert_equal 1, score.call(length: 2.5)
    assert_equal 0.25, score.call(length: 1.5)
    assert_equal 0.25, score.call(paved: 0.5)
    assert_equal 0.5, score.call(name: "Trail 2")
    # An hour and a half by train costs nothing, three hours a little, and more much more.
    assert_equal 1.5, score.call(duration: 5400)
    assert_in_delta 1.5 - 0.25, score.call(duration: 7200), 0.001
    assert_in_delta 1.5 - 0.75, score.call(duration: 10_800), 0.001
    assert_in_delta 1.5 - 1 - 0.5, score.call(duration: 12_600), 0.001
    assert_in_delta 1.3, score.call(transfers: 2), 0.001
    assert_equal 1, score.call(last_return: SATURDAY + 2.hours)
  end

  test "ranks the routes once highlights and their areas' popularity are known, varied across areas" do
    trails = (1..6).map { |index| trail(index.to_s) }
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(30 + trail.name.to_i)] })
    wiki = FakeWiki.new("2" => { title: "Big Park", article_url: "https://en.wikipedia.org/wiki/Big_Park", monthly_views: 50_000 },
      "3" => { title: "Big Park", monthly_views: 50_000 }, "4" => { title: "Big Park", monthly_views: 50_000 },
      "5" => SearchErrors::UpstreamError.new("down"))
    hiking = FakeHiking.new(trails, highlights: { trails[5].osm_id => [{ kind: "waterfall", name: "Falls" }] })
    result = search(transit: transit, hiking: hiking, wiki: wiki)

    assert_equal 6, wiki.lookups.size
    # The third route in Big Park ranks lower, for variety.
    assert_equal %w[2 3 6 4 1 5], result.trails.map(&:name)
    assert_equal({ title: "Big Park", article_url: "https://en.wikipedia.org/wiki/Big_Park", monthly_views: 50_000 },
      result.trails.first.area)
    assert_nil result.trails.find { |trail| trail.name == "5" }.area
    assert_equal [{ kind: "waterfall", name: "Falls" }], result.trails.third.highlights
    assert_equal result.trails.map(&:score), result.trails.map(&:score).sort.reverse
  end

  test "popularity is looked up for the most promising routes only" do
    scenic, plain = trail("scenic"), trail("plain")
    transit = FakeTransit.new(trips: { "scenic" => minutes(30), "plain" => minutes(30) })
    hiking = FakeHiking.new([plain, scenic], highlights: { scenic.osm_id => [{ kind: "peak", name: "Knob" }] })
    wiki = FakeWiki.new
    stub_const(TrailsService, :MAX_AREA_LOOKUPS, 1) { search(transit: transit, hiking: hiking, wiki: wiki) }
    assert_equal ["scenic"], wiki.lookups
  end

  test "a slow highlights lookup does not hold up the search" do
    release = Concurrent::Event.new
    route = trail("loop")
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    hiking = FakeHiking.new([route], highlights: { route.osm_id => [{ kind: "peak", name: "Knob" }] }, release: release)
    result = stub_const(TrailsService, :HIGHLIGHT_WAIT_SECONDS, 0.05) { search(transit: transit, hiking: hiking) }
    assert_equal [[]], result.trails.map(&:highlights)
  ensure
    release.set
  end

  test "hiking-route lookups alongside other work run on the Overpass pool, and each batch's on the search's thread" do
    pool = Class.new(Concurrent::CachedThreadPool) do
      attr_reader :posted

      def post(*arguments, &task)
        @posted = @posted.to_i + 1
        super
      end
    end.new
    original = Rails.configuration.x.overpass_pool
    Rails.configuration.x.overpass_pool = pool
    trails = [trail("a"), trail("b")]
    hiking = FakeHiking.new(trails)
    result = stub_const(TrailsService, :BATCH_SIZE, 1) do
      search(transit: FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) }), hiking: hiking)
    end
    assert_equal %w[a b], result.trails.map(&:name).sort
    # The first tiles' routes, and each batch's highlights.
    assert_equal 3, pool.posted
    assert_equal [Thread.current] * 2, hiking.threads
  ensure
    Rails.configuration.x.overpass_pool = original
    pool&.shutdown
  end

  test "a search gives up on the first tiles' routes when they take too long, but not on the other tiles'" do
    release = Concurrent::Event.new
    transit = FakeTransit.new(trips: { "a" => minutes(30) })
    error = assert_raises(SearchErrors::ProviderBusy) do
      stub_const(TrailsService, :OVERPASS_WAIT_SECONDS, 0.1) do
        search(transit: transit, hiking: FakeHiking.new([trail("a")], release: release, stuck: [:first_tiles]))
      end
    end
    assert_equal OverpassService::BUSY, error.message
    release.set

    slow = Concurrent::Event.new
    result = stub_const(TrailsService, :OVERPASS_WAIT_SECONDS, 0.1) do
      search(transit: transit, hiking: FakeHiking.new([trail("a")], far: [trail("b")], release: slow, stuck: [:other_tiles]))
    end
    assert_equal ["a"], result.trails.map(&:name)
  ensure
    release&.set
    slow&.set
  end

  test "routes are shown without highlights when they cannot be looked up" do
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")], highlights: SearchErrors::UpstreamError.new("busy")))
    assert_equal [[]], result.trails.map(&:highlights)
  end
end
