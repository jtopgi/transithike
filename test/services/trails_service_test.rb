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

  # Trips there and latest returns by route name; a name missing from returns has no way back.
  class FakeTransit
    attr_reader :departures, :planned, :stop_requests, :return_requests

    def initialize(trips: {}, returns: nil, area: { time_zone: "America/Los_Angeles", area: "Seattle, Washington" }, stops: nil)
      @trips, @returns, @area, @stops = trips, returns, area, stops
      @departures, @planned, @stop_requests, @return_requests = [], [], [], []
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

    # Without returns, every route has a way back at 9 PM.
    def latest_returns(origin:, destinations:, deadline:, earliest_return:)
      @return_requests << [deadline, earliest_return]
      raise @returns if @returns.is_a?(Exception)

      destinations.map { |destination| @returns ? @returns[destination.name] : deadline - 2.hours }
    end
  end

  # Routes by id, found nearby or near stops farther away. A batch holding a
  # failing route's id fails, and with a release event, highlights wait for it.
  class FakeHiking
    attr_reader :arguments, :access, :batches, :beyond, :threads

    # stuck names the lookups that wait for release.
    def initialize(trails, far: [], highlights: {}, failing: [], release: nil, stuck: [:highlights])
      @trails, @far, @highlights, @failing, @release, @stuck = trails, far, highlights, failing, release, stuck
      @batches, @threads = [], []
    end

    def candidates(**arguments)
      @arguments = arguments
      raise @trails if @trails.is_a?(Exception)

      { radius: 40_000, routes: @trails.map { |trail| { id: trail.osm_id } } }
    end

    def candidates_near(stops, lat:, lon:, beyond:)
      @release&.wait(5) if @stuck.include?(:candidates_near)
      @beyond = beyond
      @far.map { |trail| { id: trail.osm_id } }
    end

    def pick(routes, lat:, lon:, access:)
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

  # It is 7:02 PDT on September 22.
  setup { travel_to Time.utc(2026, 9, 22, 14, 2) }
  teardown { travel_back }

  # A 3-mile loop, about 1.5 hours to hike. Its midpoint's latitude is its name,
  # so fake lookups can tell trails apart.
  def trail(name, length: 3.0, distance: 3.0, loop: true, **attributes)
    OverpassService::Trail.new(name: name, latitude: 47.1, longitude: -122.1, length: length, distance: distance,
      osm_id: name.hash, path: [[[name, -122.1]]], loop: loop, paved: 0, **attributes)
  end

  def search(origin: "Seattle", places: FakePlaces.new, transit: FakeTransit.new, hiking: FakeHiking.new([]), wiki: FakeWiki.new, &block)
    TrailsService.search(origin: origin, places: places, transit: transit, hiking: hiking, wiki: wiki, &block)
  end

  def minutes(count)
    { duration: count * 60, transfers: 0 }
  end

  test "looks up a typed place and lists the routes with a trip there and back, best first" do
    places = FakePlaces.new
    transit = FakeTransit.new(trips: { "slow" => { duration: 3000, transfers: 1 }, "fast" => { duration: 1200, transfers: nil },
      "far" => nil })
    hiking = FakeHiking.new([trail("slow"), trail("far"), trail("fast")])
    result = search(origin: "A & B / 東京", places: places, transit: transit, hiking: hiking)

    assert_equal ["A & B / 東京"], places.queries
    assert_equal({ lat: 47, lon: -122 }, hiking.arguments)
    assert_equal %w[fast slow], result.trails.map(&:name)
    fast = result.trails.first
    assert_equal [1200, nil, "Seattle, Washington"], [fast.duration, fast.transfers, fast.origin]
    assert_equal Time.utc(2026, 9, 22, 14, 35), fast.arrival
    assert_equal Time.utc(2026, 9, 23, 4), fast.last_return
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
    assert_equal [Time.utc(2026, 9, 22, 14, 15), Time.utc(2026, 9, 23, 6)], [place.departure_time, place.return_by]
    assert_equal [2, 2, 1], events.select { |event, _| event == :checking }.map(&:last)
    assert_equal [["route 1", "route 2"], ["route 3", "route 4"], ["route 5"]],
      events.select { |event, _| event == :trails }.map { |_, found| found.map(&:name) }
    assert_equal result.trails, events.last.last
    assert events.select { |event, _| event == :trails }.flat_map(&:last).all?(&:score)
  end

  test "the first batch is from the searched area, and routes near stops beyond it follow" do
    nearby = (1..3).map { |index| trail("near #{index}") }
    farther = [trail("far 1")]
    transit = FakeTransit.new(trips: (nearby + farther).to_h { |trail| [trail.name, minutes(40)] },
      stops: [[47.1, -122.1, 30, 1, true]])
    hiking = FakeHiking.new(nearby, far: farther)
    result = stub_const(TrailsService, :BATCH_SIZE, 2) { search(transit: transit, hiking: hiking) }

    assert_equal 40_000, hiking.beyond
    assert_instance_of TransitAccess, hiking.access
    assert_equal [nearby.first(2), [nearby.last, farther.first]].map { |batch| batch.map(&:osm_id) }, hiking.batches
    assert_equal ["near 1", "near 2", "near 3", "far 1"].sort, result.trails.map(&:name).sort
  end

  test "without transit stops, nothing beyond the searched area is looked for" do
    [nil, SearchErrors::UpstreamError.new("down"), SearchErrors::ResponseTooLarge.new("dense")].each do |stops|
      hiking = FakeHiking.new([trail("a")], far: [trail("b")])
      result = search(transit: FakeTransit.new(trips: { "a" => minutes(30) }, stops: stops), hiking: hiking)
      assert_nil hiking.access
      assert_nil hiking.beyond
      assert_equal ["a"], result.trails.map(&:name)
    end
  end

  test "routes without a way back the same day, or without time to hike before it, are left out" do
    trails = [trail("roomy"), trail("stranded"), trail("rushed"), trail("long", length: 10, loop: false)]
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(60)] }, returns: {
      "roomy" => Time.utc(2026, 9, 23, 2), "stranded" => nil,
      # Arriving at 15:15 UTC, there is 1 hour 29 minutes before the last trip back.
      "rushed" => Time.utc(2026, 9, 22, 16, 44),
      # A 20-mile round trip needs the most time required, 4 hours, which is just what's left.
      "long" => Time.utc(2026, 9, 22, 19, 15)
    })
    result = search(transit: transit, hiking: FakeHiking.new(trails))

    assert_equal %w[roomy long], result.trails.map(&:name)
    deadline, earliest = transit.return_requests.sole
    assert_equal [Time.utc(2026, 9, 23, 6), Time.utc(2026, 9, 22, 15, 45)], [deadline, earliest]
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
    assert_raises(SearchErrors::InvalidInput) { search(places: FakePlaces.new(nil), hiking: hiking) }
    assert_nil hiking.arguments
  end

  test "departs now early in the day, in the origin's time zone" do
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")]))
    assert_equal Time.utc(2026, 9, 22, 14, 15), result.departure_time
    assert_equal "PDT", result.departure_time.zone
    assert_equal [result.departure_time], transit.departures
    assert_equal [result.departure_time], transit.stop_requests
  end

  test "day trips plan for the next morning from mid-morning on" do
    zone = "America/Los_Angeles"
    assert_equal Time.utc(2026, 9, 22, 16, 45), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 16, 31))
    assert_equal Time.utc(2026, 9, 23, 15), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 17, 0))
    assert_equal Time.utc(2026, 9, 23, 15), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 23, 11, 0))
    assert_equal Time.utc(2026, 9, 22, 12, 0), TrailsService.departure_time(zone, now: Time.utc(2026, 9, 22, 12, 0, 30))
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

  test "route provider failures fail the search" do
    assert_raises(SearchErrors::UpstreamError) do
      search(hiking: FakeHiking.new(SearchErrors::UpstreamError.new("Overpass is down")))
    end
  end

  test "highlights, popularity, day-hike lengths and time there rank routes up; paving, generic names and long trips down" do
    base = trail("base", length: 5, duration: 3600, transfers: 0, arrival: Time.utc(2026, 9, 22, 16),
      last_return: Time.utc(2026, 9, 23, 2))
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
    assert_in_delta 1.5 - 0.5, score.call(duration: 7200), 0.001
    assert_in_delta 1.5 - 1 - 1, score.call(duration: 10_800), 0.001
    assert_in_delta 1.3, score.call(transfers: 2), 0.001
    assert_equal 1, score.call(last_return: Time.utc(2026, 9, 22, 18))
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

  test "hiking-route lookups run on the Overpass pool, not the search's thread or the shared pool" do
    pool = Class.new(Concurrent::FixedThreadPool) do
      attr_reader :posted

      def post(*arguments, &task)
        @posted = @posted.to_i + 1
        super
      end
    end.new(2)
    original = Rails.configuration.x.overpass_pool
    Rails.configuration.x.overpass_pool = pool
    trails = [trail("a"), trail("b")]
    hiking = FakeHiking.new(trails)
    result = stub_const(TrailsService, :BATCH_SIZE, 1) do
      search(transit: FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) }), hiking: hiking)
    end
    assert_equal %w[a b], result.trails.map(&:name).sort
    # The area's routes, two batches, and highlights for each unless lookups were waiting.
    assert_operator pool.posted, :>=, 3
    refute_includes hiking.threads, Thread.current
  ensure
    Rails.configuration.x.overpass_pool = original
    pool&.shutdown
  end

  test "a search gives up on route lookups that take too long, but not on farther routes" do
    release = Concurrent::Event.new
    transit = FakeTransit.new(trips: { "a" => minutes(30) }, stops: [[47.1, -122.1, 30, 1, true]])
    error = assert_raises(SearchErrors::UpstreamError) do
      stub_const(TrailsService, :OVERPASS_WAIT_SECONDS, 0.1) do
        search(transit: transit, hiking: FakeHiking.new([trail("a")], release: release, stuck: [:trails_for]))
      end
    end
    assert_equal TrailsService::BUSY, error.message
    release.set

    slow = Concurrent::Event.new
    result = stub_const(TrailsService, :OVERPASS_WAIT_SECONDS, 0.1) do
      search(transit: transit, hiking: FakeHiking.new([trail("a")], far: [trail("b")], release: slow, stuck: [:candidates_near]))
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
