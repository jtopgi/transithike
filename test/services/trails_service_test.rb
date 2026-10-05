require "test_helper"
require_relative "../support/guide_fixtures"

class TrailsServiceTest < ActiveSupport::TestCase
  include GuideFixtures

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

  # The major stations near the origin; the stations trains reach from each,
  # by its name when they differ; and trips there, trips by city transit, and
  # latest returns by route name, with trips from some stations by their names
  # in from. A name missing from returns has no way back.
  class FakeTransit
    attr_reader :departure_times, :planned, :station_requests, :return_requests, :city_requests, :major_requests, :returned_for,
      :timetables

    # By default, King Street station at the origin, one station 55 km north of
    # it, and no trips by city transit. Each hike has three trips there, half
    # an hour apart, and three back, an hour apart until the last, which leaves
    # before dark; there and back give some fewer, by name, and plans, an
    # exception or exceptions by name, fails planning them, or a block by name
    # holds it up.
    def initialize(trips: {}, city: {}, returns: nil, area: { time_zone: "America/Los_Angeles", area: "Seattle, Washington" },
      stations: [[47.5, -122.0, 60]], major: [STATION], from: {}, there: {}, back: {}, plans: nil)
      @trips, @city, @returns, @area, @stations, @major, @from = trips, city, returns, area, stations, major, from
      @there, @back, @plans = there, back, plans
      @departure_times, @planned, @station_requests, @return_requests, @city_requests, @major_requests = [], [], [], [], [], []
      @returned_for, @timetables, @names = [], [], {}
    end

    def area(latitude, longitude)
      raise @area if @area.is_a?(Exception)

      @area
    end

    def major_stations(origin:, departure_time:)
      @major_requests << origin
      raise @major if @major.is_a?(Exception)

      @major
    end

    def rail_stations(origin:, departure_time:)
      @station_requests << departure_time
      stations = @stations.is_a?(Hash) ? @stations.fetch(origin.name) : @stations
      raise stations if stations.is_a?(Exception)

      stations
    end

    def trips(origin:, destinations:, departure_time:, modes: nil)
      learn(destinations)
      if modes
        @city_requests << modes
        raise @city if @city.is_a?(Exception)

        return destinations.map { |destination| @city[destination.name] }
      end
      @departure_times << departure_time
      raise @trips if @trips.is_a?(Exception)

      from = @from.fetch(origin.name, {})
      destinations.map { |destination| from.fetch(destination.name) { @trips.fetch(destination.name) } }
    end

    def trip(origin:, destination:, departure_time:)
      @planned << destination.name
      { duration: 1200, transfers: 0 }
    end

    # Without returns, every route has a way back at 9 PM.
    def latest_returns(origin:, destinations:, deadline:, earliest_return:)
      learn(destinations)
      @return_requests << [deadline, earliest_return]
      @returned_for.concat(destinations.map(&:name))
      raise @returns if @returns.is_a?(Exception)

      destinations.map { |destination| @returns ? @returns[destination.name] : deadline - 2.hours }
    end

    # The trips there for a hike's timetable, each riding as long as trips says.
    def departures(origin:, destination:, time:, latest:, arrive_by: nil, by_train: true)
      name = named(destination)
      case (failure = @plans.is_a?(Hash) ? @plans[name] : @plans)
      when Proc then failure.call
      when Exception then raise failure
      end

      @timetables << name
      # Where the one-request API fails, trips there ride 20 minutes, as #trip plans them.
      ride = @from.fetch(origin.name, {}).fetch(name) { @trips.is_a?(Hash) ? @trips[name] : { duration: 1200 } }&.dig(:duration)
      return [] unless ride

      (0...@there.fetch(name, 3)).map { |index| time + (index * 30).minutes }.select { |leave| leave <= latest }
        .map { |leave| { departure: leave.utc.iso8601, arrival: (leave + ride).utc.iso8601, legs: [] } }
    end

    def journey(origin:, destination:, time:) = nil

    # The trips back an hour apart after earliest until the last trip back, as
    # #latest_returns gives it, that leaves by leave_by.
    def ways_back(origin:, destination:, like:, earliest:, deadline:, leave_by: nil, follow: true)
      name = named(origin)
      last = @returns.is_a?(Hash) ? @returns[name] : deadline - 2.hours
      last = [last, leave_by].compact.min if last
      count = @back.fetch(name.delete_suffix(" finish"), 3)
      leaving = last ? (0...count).map { |index| last - index.hours }.select { |time| time >= earliest }.reverse : []
      trips = leaving.map { |time| { departure: time.utc.iso8601, arrival: (time + 1.hour).utc.iso8601, legs: [] } }
      { back: trips.first, last: trips.last, same_way: true, trips: trips }
    end

    private

    # Trips are planned to places by where they are, so their names are learned from the routes and their far ends.
    def learn(places)
      places.each { |place| @names[[place.latitude, place.longitude]] = place.name }
    end

    def named(place)
      @names.fetch([place.latitude, place.longitude], place.name)
    end
  end

  # Routes by id, in the first tiles or the others. A batch holding a failing
  # route's id fails, and with a release event, stuck lookups wait for it.
  class FakeHiking
    FIRST_TILE = [47.5, -122.5].freeze

    attr_reader :access, :batches, :reliefs, :stations, :tile_requests, :threads

    # stuck names the lookups that wait for release: :first_tiles, :other_tiles, :trails_for, or :highlights.
    def initialize(trails, far: [], highlights: {}, failing: [], release: nil, stuck: [:highlights], tiles_failing: [])
      @trails, @far, @highlights, @failing, @release, @stuck = trails, far, highlights, failing, release, stuck
      @tiles_failing = tiles_failing
      @batches, @threads, @tile_requests, @reliefs = [], [], Concurrent::Array.new, []
    end

    # One tile, or five when there are routes in the others.
    def tiles(stations)
      @stations = stations
      (0...(@far.empty? ? 1 : 5)).map { |index| [47.5, -122.5 + index * 0.5] }
    end

    # Tiles failing names the lookups, :first_tiles or :other_tiles, some of whose tiles don't load.
    def routes_in(tiles, failures: nil)
      first = tiles.include?(FIRST_TILE)
      @release&.wait(5) if @stuck.include?(first ? :first_tiles : :other_tiles)
      @tile_requests << tiles
      raise @trails if first && @trails.is_a?(Exception)

      failures&.push(SearchErrors::UpstreamError.new("busy")) if @tiles_failing.include?(first ? :first_tiles : :other_tiles)

      (first ? @trails : @far).map { |trail| { id: trail.osm_id, latitude: trail.latitude, longitude: trail.longitude } }
    end

    def pick(routes, access:, relief:)
      @access = access
      @reliefs << relief
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

  # Terrain by route name; a lookup including a name mapped to an exception fails,
  # and with a release event, lookups wait for it. Relief is by route id, and a
  # lookup including an id mapped to an exception fails.
  # The traffic noise along routes by name, unknown for others; with failure, the lookup fails.
  class FakeNoise
    attr_reader :asked

    def initialize(by_name = {}, failure: nil)
      @by_name, @failure, @asked = by_name, failure, Concurrent::Array.new
    end

    def noise(trails)
      @asked.concat(trails.map(&:name))
      raise @failure if @failure

      trails.to_h { |trail| [trail.osm_id, @by_name[trail.name]] }
    end
  end

  class FakeElevation
    attr_reader :lookups, :relief_lookups

    def initialize(terrain = {}, release: nil, relief: {})
      @terrain, @release, @relief, @lookups, @relief_lookups = terrain, release, relief, Concurrent::Array.new, Concurrent::Array.new
    end

    def reliefs(routes)
      @relief_lookups << routes.pluck(:id)
      failure = routes.map { |route| @relief[route[:id]] }.grep(Exception).first
      raise failure if failure

      routes.to_h { |route| [route[:id], @relief[route[:id]]] }.compact
    end

    def terrain(trails)
      @release&.wait(5)
      @lookups.concat(trails.map(&:name))
      failure = trails.map { |trail| @terrain[trail.name] }.grep(Exception).first
      raise failure if failure

      trails.to_h { |trail| [trail.osm_id, @terrain[trail.name]] }
    end
  end

  # It is 7:02 AM PDT on Tuesday, September 22, so trips are for Saturday the 26th.
  setup { travel_to Time.utc(2026, 9, 22, 14, 2) }
  teardown { travel_back }

  SATURDAY = Time.utc(2026, 9, 26, 15)
  STATION = Station.new(name: "King Street", latitude: 47.0, longitude: -122.0, id: "king-street", time_zone: "America/Los_Angeles")
  # 10 km east of King Street, so getting there across the city takes 40 minutes longer.
  EASTSIDE = Station.new(name: "Eastside", latitude: 47.0, longitude: -121.869, id: "eastside", time_zone: "America/Los_Angeles")

  # A 3-mile loop, about 1.5 hours to hike, in an area of its own about 11 km
  # from each other trail's, unless placed at a latitude.
  def trail(name, length: 3.0, distance: 30.0, loop: true, at: nil, **attributes)
    @trails_made = @trails_made.to_i + 1
    latitude = at || 47.0 + @trails_made * 0.1
    OverpassService::Trail.new(name: name, latitude: latitude, longitude: -122.1, length: length, distance: distance,
      osm_id: name.hash, path: [[[latitude, -122.1], [latitude + 0.01, -122.1]]], loop: loop, paved: 0, **attributes)
  end

  def search(origin: "Seattle", day: nil, near: nil, places: FakePlaces.new, transit: FakeTransit.new,
    hiking: FakeHiking.new([]), elevation: FakeElevation.new, noise: quiet_unknown, &block)
    TrailsService.search(origin: origin, day: day, near: near, places: places, transit: transit, hiking: hiking,
      elevation: elevation, noise: noise, &block)
  end

  # A noise map that knows no routes, the same for a test's searches, so they can share station searches.
  def quiet_unknown
    @quiet_unknown ||= FakeNoise.new
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
    assert_equal [1200, nil, "King Street", STATION], [fast.duration, fast.transfers, fast.origin, fast.station]
    assert_equal SATURDAY + 20.minutes, fast.arrival
    # The last trip back leaves before dark, at 7:29 PM, though trips home run until 9 PM.
    assert_equal Time.utc(2026, 9, 27, 2, 29), fast.last_return
    assert_equal "Seattle, Washington", result.area
    assert_equal [STATION], result.stations
    assert_equal [result.place], transit.major_requests
    assert result.returns_checked
    assert result.complete
  end

  test "routes are picked knowing how far the land rises around them, and without it when that can't be looked up" do
    near, far = trail("near"), trail("far")
    transit = FakeTransit.new(trips: { "near" => minutes(30), "far" => minutes(30) })
    hiking = FakeHiking.new([near], far: [far])
    elevation = FakeElevation.new(relief: { near.osm_id => 120, far.osm_id => 450 })
    assert_equal %w[far near], search(transit: transit, hiking: hiking, elevation: elevation).trails.map(&:name).sort

    # The first batch is picked with the nearest routes' relief, the rest with every route's,
    # each route's looked up once.
    assert_equal [{ near.osm_id => 120 }, { near.osm_id => 120, far.osm_id => 450 }], hiking.reliefs
    assert_equal [[near.osm_id], [far.osm_id]], elevation.relief_lookups

    hiking = FakeHiking.new([near])
    failing = FakeElevation.new(relief: { near.osm_id => SearchErrors::UpstreamError.new("down") })
    assert_equal %w[near], search(transit: transit, hiking: hiking, elevation: failing).trails.map(&:name)
    assert_equal [{}, {}], hiking.reliefs
  end

  test "a hike's location is its town and region, with its country when it isn't the starting point's" do
    places = Class.new do
      def locality(latitude, _longitude)
        raise SearchErrors::UpstreamError, "down" if latitude == 1

        { 47 => { locality: "Seattle", region: "Washington", country: "United States" },
          48 => { locality: "Mount Vernon", region: "Washington", country: "United States" },
          49 => { locality: "Abbotsford", region: "British Columbia", country: "Canada" },
          50 => { locality: "Hope", country: "Canada" } }[latitude]
      end
    end.new
    at = ->(latitude) { Place.new(latitude: latitude, longitude: -122) }
    assert_equal "Mount Vernon, Washington", TrailsService.location(at.(48), at.(47), places: places)
    assert_equal "Abbotsford, British Columbia, Canada", TrailsService.location(at.(49), at.(47), places: places)
    assert_equal "Hope", TrailsService.location(at.(50), at.(49), places: places)
    # Without the starting point's country, the country is left out, and nothing nearby is no location.
    assert_equal "Abbotsford, British Columbia", TrailsService.location(at.(49), at.(1), places: places)
    assert_nil TrailsService.location(at.(51), at.(47), places: places)
  end

    test "results are reported as they are found: the place, each batch checked, each hike once its trips are planned, and the ranking" do
    trails = (1..5).map { |index| trail("route #{index}") }
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(30)] })
    events = []
    result = stub_const(TrailsService, :BATCH_SIZE, 2) do
      search(transit: transit, hiking: FakeHiking.new(trails)) { |event, payload| events << [event, payload] }
    end

    assert_equal [:place, :checking, :trails, :trails, :checking, :trails, :trails, :checking, :trails, :update], events.map(&:first)
    place = events.first.last
    assert_equal [SATURDAY, Time.utc(2026, 9, 27, 6), [STATION]], [place.departure_time, place.return_by, place.stations]
    assert_equal [[2, STATION], [2, STATION], [1, STATION]], events.select { |event, _| event == :checking }.map(&:last)
    assert_equal [["route 1"], ["route 2"], ["route 3"], ["route 4"], ["route 5"]],
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

  test "routes are left out without a way back the same day that leaves time to hike all of them" do
    trails = [trail("roomy"), trail("stranded"), trail("rushed"), trail("long", length: 10, loop: false),
      trail("through", length: 6, loop: false), trail("there and back", length: 2, loop: false),
      trail("late bus", length: 12, loop: false)]
    deadline = Time.utc(2026, 9, 27, 6)
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(60)] }, returns: {
      "roomy" => Time.utc(2026, 9, 27, 2), "stranded" => nil,
      # Arriving at 16:00 UTC, a 3-mile loop takes 1.5 hours, and the last trip back must leave half an hour after.
      "rushed" => Time.utc(2026, 9, 26, 17, 59),
      # Ten miles out and back take 10 hours, more than the 4 left, and nothing leaves from the far end.
      "long" => Time.utc(2026, 9, 26, 20), "long finish" => nil,
      # Six miles to the far end take 3 hours, and trips home from there run until 22:00 PDT, after dark.
      "through" => Time.utc(2026, 9, 26, 18), "through finish" => deadline - 1.hour,
      # Two miles out and back take 2 hours, comfortable enough to come back the same way.
      "there and back" => Time.utc(2026, 9, 26, 20, 30), "there and back finish" => deadline - 3.hours,
      # Twelve miles out and back don't fit, but 6 hours to the far end do, before its last bus at 5:30 PM PDT,
      # though that leaves hours before 11 PM.
      "late bus" => Time.utc(2026, 9, 26, 19), "late bus finish" => Time.utc(2026, 9, 27, 0, 30)
    })
    result = search(transit: transit, hiking: FakeHiking.new(trails))

    found = result.trails.index_by(&:name)
    assert_equal ["late bus", "roomy", "there and back", "through"], found.keys.sort
    assert_equal [:loop, nil, Time.utc(2026, 9, 27, 2)], found["roomy"].to_h.values_at(:plan, :finish, :last_return)
    through = trails.find { |trail| trail.name == "through" }
    # The last trip back leaves before dark, at 7:29 PM.
    assert_equal [:through, through.path.first.last, Time.utc(2026, 9, 27, 2, 29)],
      found["through"].to_h.values_at(:plan, :finish, :last_return)
    assert_equal [:out_and_back, nil], found["there and back"].to_h.values_at(:plan, :finish)
    assert_equal [:through, Time.utc(2026, 9, 27, 0, 30)], found["late bus"].to_h.values_at(:plan, :last_return)
    # One request asks for the last trips back from every route and every linear route's far end.
    assert_equal [deadline, SATURDAY + 90.minutes], transit.return_requests.sole
  end

  test "hikes have to be done by sunset, while the trains back can run after dark" do
    # It's Tuesday, December 15, so trips are for Saturday the 19th, when the sun sets at 4:20 PM PST there.
    travel_to Time.utc(2026, 12, 15, 14, 2)
    trails = [trail("short day"), trail("long day", length: 16), trail("late start", length: 5, loop: false)]
    trips = { "short day" => minutes(60), "long day" => minutes(60), "late start" => minutes(210) }
    transit = FakeTransit.new(trips: trips)
    found = search(transit: transit, hiking: FakeHiking.new(trails)).trails.index_by(&:name)

    # Arriving at 9 AM, 16 miles take until 5 PM, after dark, though the last trip back is at 9 PM.
    assert_equal ["late start", "short day"], found.keys.sort
    assert_equal Time.utc(2026, 12, 20, 0, 20), found["short day"].sunset
    # Arriving at 11:30 AM, 10 miles out and back would take until 4:30 PM, so the route is hiked one way, done by 2 PM.
    assert_equal :through, found["late start"].plan
    # Routes without the daylight to hike even one way aren't asked about trips back.
    assert_not_includes transit.returned_for, "long day"

    # When the trips back can't be checked, hikes still have to be done by sunset.
    unchecked = FakeTransit.new(trips: trips, returns: SearchErrors::UpstreamError.new("Transit is down"))
    assert_equal ["short day"], search(transit: unchecked, hiking: FakeHiking.new(trails)).trails.map(&:name)
  end

  test "hikes take an hour every 2 miles, out and back twice the route, and at least an hour and a half" do
    assert_equal 1.5, TrailsService.hike_hours(trail("short", length: 1.2))
    assert_equal 15, TrailsService.hike_hours(trail("epic", length: 30))
    there_and_back = trail("there and back", length: 5, loop: false)
    assert_equal [10, 5, 5.5], [TrailsService.hike_miles(there_and_back), TrailsService.hike_hours(there_and_back),
      TrailsService.required_hours(there_and_back)]
    there_and_back.plan = :through
    assert_equal [5, 2.5], [TrailsService.hike_miles(there_and_back), TrailsService.hike_hours(there_and_back)]
  end

  test "linear routes reached near an end can be hiked to the other, and routes with close ends are loops" do
    near_ends = trail("near ends", loop: false).tap { |route| route.path = [[[47.0, -122.1], [47.005, -122.1]]] }
    assert TrailsService.loop?(near_ends)
    assert_nil TrailsService.finish(near_ends)
    linear = trail("linear", loop: false, at: 47.0)
    assert_equal [47.01, -122.1], TrailsService.finish(linear)
    # Reached halfway along an 11 km route, it's hiked out and back.
    linear.latitude = 47.05
    linear.path = [(0..10).map { |step| [47.0 + step * 0.01, -122.1] }]
    assert_nil TrailsService.finish(linear)
    refute TrailsService.loop?(linear)
  end

  test "when the quick check of the way back fails, each route's planned trips still check it, and the result says so" do
    # Twenty miles out and back take 20 hours, more than the day has.
    transit = FakeTransit.new(trips: { "a" => minutes(30), "epic" => minutes(30) }, returns: SearchErrors::UpstreamError.new("changed"))
    result = search(transit: transit, hiking: FakeHiking.new([trail("a"), trail("epic", length: 20, loop: false)]))
    assert_equal ["a"], result.trails.map(&:name)
    assert_equal Time.utc(2026, 9, 27, 2, 29), result.trails.first.last_return
    refute result.returns_checked
  end

  test "in the US, only routes under 45 dB along most of the way are shown or planned, and the quieter rank higher" do
    trails = %w[forest edge suburb highway unknown].map { |name| trail(name) }
    noise = FakeNoise.new({ "forest" => { quiet: 1.0, typical: 0, loudest: 0 }, "edge" => { quiet: 0.6, typical: 0, loudest: 50 },
      "suburb" => { quiet: 0.3, typical: 45, loudest: 55 }, "highway" => { quiet: 0.0, typical: 70, loudest: 80 } })
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(60)] })
    found = search(transit: transit, hiking: FakeHiking.new(trails), noise: noise).trails.index_by(&:name)

    assert_equal %w[edge forest unknown], found.keys.sort
    assert_equal [{ quiet: 1.0, typical: 0, loudest: 0 }, nil], found.values_at("forest", "unknown").map(&:noise)
    # Quiet surroundings count up to two points, and unknown ones nothing.
    assert_equal [2.0, 1.2, 0.0], found.values_at("forest", "edge", "unknown").map { |trail| TrailsService.scenic(trail) }
    assert_equal %w[edge forest highway suburb unknown], noise.asked.sort
    assert_empty transit.timetables & %w[suburb highway]
  end

  test "noise is looked up from stations on the noise map, whoever searches, and when it fails, routes are kept without it" do
    noise = FakeNoise.new({ "a" => { quiet: 0.0, typical: 70, loudest: 80 } })
    # A station across the border, in Vancouver, isn't on it, even for searches from Seattle.
    vancouver = Station.new(name: "Pacific Central", latitude: 49.27, longitude: -123.1, id: "pacific-central",
      time_zone: "America/Vancouver")
    canada = FakeTransit.new(trips: { "a" => minutes(30) }, major: [vancouver])
    assert_equal ["a"], search(transit: canada, hiking: FakeHiking.new([trail("a")]), noise: noise).trails.map(&:name)
    assert_empty noise.asked
    # King Street is, even for searches from Vancouver's time zone.
    across = FakeTransit.new(trips: { "a" => minutes(30) }, area: { time_zone: "America/Vancouver", area: "Vancouver" })
    assert_empty search(transit: across, hiking: FakeHiking.new([trail("a")]), noise: noise).trails
    assert_equal ["a"], noise.asked

    failing = FakeNoise.new(failure: SearchErrors::UpstreamError.new("The noise map is down"))
    found = search(transit: FakeTransit.new(trips: { "b" => minutes(30) }), hiking: FakeHiking.new([trail("b")]), noise: failing)
    assert_equal [["b"], [nil]], [found.trails.map(&:name), found.trails.map(&:noise)]
  end

  test "hikes need at least three trips there that arrive in time and three back before dark, so missing one isn't a worry" do
    trails = %w[frequent sparse-there sparse-back late-there].map { |name| trail(name) }
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(60)] }, there: { "sparse-there" => 2 },
      back: { "sparse-back" => 2 },
      # The last trip back, at 7 PM, leaves only an hour and a half after a trip there at 4:30 PM, too soon to hike after.
      returns: trails.to_h { |trail| [trail.name, Time.utc(2026, 9, 27, 2)] }.merge("late-there" => Time.utc(2026, 9, 26, 18)))
    result = search(transit: transit, hiking: FakeHiking.new(trails))
    assert_equal ["frequent"], result.trails.map(&:name)
    assert result.complete
    # Without enough trips there, the trips back aren't planned.
    assert_equal %w[frequent late-there sparse-back sparse-there], transit.timetables.sort
  end

  test "a search gives up on hikes whose trips aren't planned while no others are, as when the pool is stuck" do
    stuck = Concurrent::Event.new
    transit = FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) }, plans: { "b" => -> { stuck.wait(10) } })
    result = stub_const(TrailsService, :TRIP_QUIET_SECONDS, 0.5) do
      search(transit: transit, hiking: FakeHiking.new([trail("a"), trail("b")]))
    end
    assert_equal ["a"], result.trails.map(&:name)
    refute result.complete
  ensure
    stuck&.set
  end

  test "once planning is stuck, the hikes still waiting are given up on together, and those not started aren't planned" do
    stuck = Concurrent::Event.new
    trails = %w[a b c d].map { |name| trail(name) }
    # Three hikes hold the pool's three threads, and the fourth waits its turn.
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(30)] },
      plans: trails.to_h { |trail| [trail.name, -> { stuck.wait(10) }] })
    planned = Rails.configuration.x.trips_planned.value
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(SearchErrors::ProviderBusy) do
      stub_const(TrailsService, :TRIP_QUIET_SECONDS, 0.5) { search(transit: transit, hiking: FakeHiking.new(trails)) }
    end
    # One quiet spell, rather than one for each hike.
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
    stuck.set
    100.times { Rails.configuration.x.trips_planned.value >= planned + 4 ? break : sleep(0.05) }
    # The fourth hike's turn came after the search gave up, so its trips weren't planned.
    assert_equal 3, transit.timetables.size
  ensure
    stuck&.set
  end

  test "routes whose trips can't be planned are left out, and a search that can't plan any fails" do
    busy = SearchErrors::UpstreamError.new("Transit is busy")
    transit = FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) }, plans: { "b" => busy })
    result = search(transit: transit, hiking: FakeHiking.new([trail("a"), trail("b")]))
    assert_equal ["a"], result.trails.map(&:name)
    refute result.complete

    transit = FakeTransit.new(trips: { "a" => minutes(30) }, plans: busy)
    assert_equal "Transit is busy", assert_raises(SearchErrors::UpstreamError) { search(transit: transit, hiking: FakeHiking.new([trail("a")])) }.message
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
    assert_equal [SATURDAY], transit.departure_times
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

  test "scenery and day-hike lengths rank routes up; paving, generic names and long trips down" do
    base = trail("base", length: 5, duration: 3600, transfers: 0, arrival: SATURDAY + 1.hour,
      last_return: Time.utc(2026, 9, 27, 2))
    score = ->(**changes) { TrailsService.score(base.dup.tap { |copy| changes.each { |key, value| copy[key] = value } }) }
    assert_equal 1.5, score.call

    # Scenery counts 0.6 a point.
    assert_in_delta 1.5 + 1.2, score.call(highlights: [{ kind: "waterfall", name: "Twin Falls" }]), 0.001
    assert_in_delta 1.5 + 2.1, score.call(terrain: { climb: 200, relief: 350 }), 0.001
    assert_equal 2, score.call(notable: true)
    assert_equal 1, score.call(length: 2.5)
    assert_equal 0.25, score.call(length: 1.5)
    # Out and back, the hike is twice as long.
    assert_equal 1.5, score.call(length: 1.5, loop: false, plan: :out_and_back)
    assert_equal 0.25, score.call(paved: 0.5)
    assert_equal 0.5, score.call(name: "Trail 2")
    # Three hours there and back costs nothing, four a little, and more than six much more.
    assert_equal 1.5, score.call(duration: 5400)
    assert_in_delta 1.5 - 0.25, score.call(duration: 7200), 0.001
    assert_in_delta 1.5 - 0.75, score.call(duration: 10_800), 0.001
    assert_in_delta 1.5 - 1 - 0.5, score.call(duration: 12_600), 0.001
    assert_in_delta 1.3, score.call(transfers: 2), 0.001
  end

  test "views count for how far a route climbs or its high point stands above the land around it, and for mapped vistas" do
    scenic = ->(terrain: nil, highlights: []) { TrailsService.scenic(trail("route", terrain: terrain, highlights: highlights)) }
    assert_equal 0, scenic.call
    assert_equal 3.5, scenic.call(terrain: { climb: 200, relief: 350 })
    assert_equal 2.5, scenic.call(terrain: { climb: 250, relief: 90 })
    # Up to four points, however high.
    assert_equal 4, scenic.call(terrain: { climb: 900, relief: 700 })
    assert_equal 3.5, scenic.call(terrain: { climb: 100, relief: 300 }, highlights: [{ kind: "viewpoint" }] * 4)
    assert_equal 0.25, scenic.call(highlights: [{ kind: "peak", name: "Knob" }, { kind: "peak" }])
    # A famous summit or viewpoint, with a Wikipedia article.
    assert_equal 1.25, scenic.call(highlights: [{ kind: "peak", name: "Bear Mountain", notable: true }])
  end

  test "waterfalls count for a name, a Wikipedia article, and their height" do
    waterfall = ->(**highlight) { TrailsService.scenic(trail("route", highlights: [{ kind: "waterfall", **highlight }])) }
    assert_equal 1.5, waterfall.call
    assert_equal 2, waterfall.call(name: "Twin Falls")
    assert_equal 3.5, waterfall.call(name: "Twin Falls", height: 10.0, notable: true)
    assert_equal 4.5, waterfall.call(name: "Kaaterskill Falls", height: 79.0, notable: true)
  end

  test "one grand view outranks many small ones: the best feature counts in full, the next half, and the one after a quarter" do
    grand = trail("grand", terrain: { climb: 300, relief: 400 })
    many = trail("many", terrain: { climb: 40, relief: 50 }, highlights: [{ kind: "viewpoint" }] * 10 +
      [{ kind: "peak", name: "Knob" }, { kind: "peak", name: "Nubble" }] + [{ kind: "waterfall" }] * 2)
    assert_equal 4, TrailsService.scenic(grand)
    # 1.5 and 1.5 for two waterfalls, and 1.25 for small views: 1.5 + 0.75 + 0.3125.
    assert_equal 2.56, TrailsService.scenic(many)
    assert_operator TrailsService.score(grand.tap { |route| route.duration = 3600 }), :>,
      TrailsService.score(many.tap { |route| route.duration = 3600 })
    both = trail("both", terrain: { climb: 400, relief: 400 }, highlights: [{ kind: "waterfall", name: "Falls" }] * 2)
    assert_equal 4 + 1 + 0.5, TrailsService.scenic(both)
  end

  test "ranks the routes once highlights and terrain are known, varied across areas" do
    trails = (1..6).map { |index| trail(index.to_s, at: (47.3 if index.between?(2, 4))) }
    transit = FakeTransit.new(trips: trails.to_h { |trail| [trail.name, minutes(30 + trail.name.to_i)] })
    views = { climb: 100, relief: 300 }
    elevation = FakeElevation.new({ "2" => views, "3" => views, "4" => views, "5" => SearchErrors::UpstreamError.new("down") })
    hiking = FakeHiking.new(trails, highlights: { trails[5].osm_id => [{ kind: "waterfall", name: "Falls" }] })
    result = stub_const(TrailsService, :TERRAIN_CHUNK, 1) { search(transit: transit, hiking: hiking, elevation: elevation) }

    # Each route's terrain is looked up while its batch's transit is checked, and once more for those still without it.
    assert_equal({ "1" => 2, "2" => 1, "3" => 1, "4" => 1, "5" => 2, "6" => 2 }, elevation.lookups.tally)
    # The third route within 3 km of two better ones ranks lower, for variety.
    assert_equal %w[2 3 6 4 1 5], result.trails.map(&:name)
    assert_equal views, result.trails.first.terrain
    assert_nil result.trails.find { |trail| trail.name == "5" }.terrain
    assert_equal [{ kind: "waterfall", name: "Falls" }], result.trails.third.highlights
    assert_equal result.trails.map(&:score), result.trails.map(&:score).sort.reverse
  end

  test "terrain is looked up for each batch's routes, and once more for the most promising still without it" do
    scenic, plain = trail("scenic"), trail("plain")
    transit = FakeTransit.new(trips: { "scenic" => minutes(30), "plain" => minutes(30) })
    hiking = FakeHiking.new([plain, scenic], highlights: { scenic.osm_id => [{ kind: "peak", name: "Knob" }] })
    elevation = FakeElevation.new
    stub_const(TrailsService, :MAX_TERRAIN_LOOKUPS, 1) { search(transit: transit, hiking: hiking, elevation: elevation) }
    assert_equal({ "scenic" => 2, "plain" => 1 }, elevation.lookups.tally)
  end

  test "a slow terrain lookup does not hold up the search" do
    release = Concurrent::Event.new
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    elevation = FakeElevation.new({ "loop" => { climb: 300, relief: 300 } }, release: release)
    result = stub_const(TrailsService, :TERRAIN_WAIT_SECONDS, 0.05) do
      search(transit: transit, hiking: FakeHiking.new([trail("loop")]), elevation: elevation)
    end
    assert_equal [nil], result.trails.map(&:terrain)
  ensure
    release.set
  end

  test "a slow highlights lookup does not hold up a search a visitor waits on, but one in the background waits for it" do
    release = Concurrent::Event.new
    route = trail("loop")
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    knob = [{ kind: "peak", name: "Knob" }]
    hiking = FakeHiking.new([route], highlights: { route.osm_id => knob }, release: release)
    result = stub_const(TrailsService, :HIGHLIGHT_WAIT_SECONDS, 0.05) do
      ProviderSlots.with_priority(ProviderSlots::VISITOR) { search(transit: transit, hiking: hiking) }
    end
    assert_equal [[]], result.trails.map(&:highlights)

    # As guide builds' searches are.
    later = FakeHiking.new([trail("loop", at: route.latitude).tap { |each| each.osm_id = route.osm_id }],
      highlights: { route.osm_id => knob }, release: Concurrent::Event.new.tap { |event| Thread.new { sleep 0.2; event.set } })
    result = stub_const(TrailsService, :HIGHLIGHT_WAIT_SECONDS, 0.05) { search(transit: transit, hiking: later) }
    assert_equal [knob], result.trails.map(&:highlights)
  ensure
    release.set
  end

  test "hiking-route lookups alongside other work run on the Overpass pool, and each batch's on the station search's thread" do
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
    assert_equal 1, hiking.threads.uniq.size
    refute_includes hiking.threads, Thread.current
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
    # The scenery farther out went unchecked.
    refute result.complete

    # As it does when only some of the tiles' routes load.
    transit = FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) })
    [:first_tiles, :other_tiles].each do |lookup|
      result = search(transit: transit, hiking: FakeHiking.new([trail("a")], far: [trail("b")], tiles_failing: [lookup]))
      assert_equal [%w[a b], false], [result.trails.map(&:name).sort, result.complete], lookup
    end
    assert search(transit: transit, hiking: FakeHiking.new([trail("a")], far: [trail("b")])).complete
  ensure
    release&.set
    slow&.set
  end

  test "hikes are found from each station and shown from the one that gets there soonest, counting the trip to it" do
    trails = [trail("both near"), trail("east"), trail("king street")]
    # Eastside gets to the first sooner by train, but not once the 40 minutes across the city to it count.
    transit = FakeTransit.new(major: [STATION, EASTSIDE], trips: { "both near" => minutes(60), "east" => minutes(100), "king street" => minutes(50) },
      from: { "Eastside" => { "both near" => minutes(45), "east" => minutes(30), "king street" => nil } })
    events = []
    result = search(transit: transit, hiking: FakeHiking.new(trails)) { |event, payload| events << [event, payload] }

    found = result.trails.to_h { |trail| [trail.name, [trail.station.name, trail.duration / 60]] }
    assert_equal({ "both near" => ["King Street", 60], "east" => ["Eastside", 30], "king street" => ["King Street", 50] }, found)
    assert_equal [STATION, EASTSIDE], result.stations
    # A route is shown again only from a station that gets there sooner, and is last shown or updated as found.
    changes = events.filter_map do |event, payload|
      payload.map { |trail| [event, trail.name, trail.station.name] } if %i[trails update].include?(event)
    end.flatten(1)
    shown = changes.select { |event, _, _| event == :trails }
    assert_equal shown.uniq, shown
    assert_equal found.transform_values(&:first), changes.to_h { |_, name, station| [name, station] }
  end

  test "when a station's search fails, the others' hikes are still shown, and with none at all, the search fails" do
    transit = FakeTransit.new(major: [STATION, EASTSIDE], trips: { "a" => minutes(30) },
      stations: { "King Street" => [[47.5, -122.0, 60]], "Eastside" => SearchErrors::UpstreamError.new("down") })
    result = search(transit: transit, hiking: FakeHiking.new([trail("a")]))
    assert_equal [["a", "King Street"]], result.trails.map { |trail| [trail.name, trail.station.name] }
    refute result.complete

    transit = FakeTransit.new(major: [STATION, EASTSIDE], stations: { "King Street" => SearchErrors::ProviderBusy.new("busy"),
      "Eastside" => SearchErrors::UpstreamError.new("down") })
    assert_raises(SearchErrors::UpstreamError) { search(transit: transit, hiking: FakeHiking.new([trail("a")])) }
  end

  test "without major stations near, there are no hikes to look for" do
    transit = FakeTransit.new(major: [])
    hiking = FakeHiking.new([trail("a")])
    events = []
    result = search(transit: transit, hiking: hiking) { |event, _| events << event }
    assert_empty result.trails
    assert_equal [:place], events
    assert_empty transit.station_requests
    assert_empty hiking.tile_requests

    assert_raises(SearchErrors::UpstreamError) { search(transit: FakeTransit.new(major: SearchErrors::UpstreamError.new("down"))) }
  end

  test "a batch whose routes can't be looked up at once is checked again in halves" do
    good = (1..3).map { |index| trail("good #{index}") }
    bad = trail("bad")
    transit = FakeTransit.new(trips: (good + [bad]).to_h { |trail| [trail.name, minutes(30)] })
    hiking = FakeHiking.new(good + [bad], failing: [bad.osm_id])
    result = stub_const(TrailsService, :BATCH_SIZE, 4) { search(transit: transit, hiking: hiking) }

    ids = (good + [bad]).map(&:osm_id)
    assert_equal [ids, ids.first(2), ids.last(2)], hiking.batches
    assert_equal ["good 1", "good 2"], result.trails.map(&:name).sort
    refute result.complete
  end

  test "a station's search is shared by searches that start there at once, and kept for a while once done" do
    cache = ActiveSupport::Cache::MemoryStore.new
    release = Concurrent::Event.new
    hiking = FakeHiking.new([trail("a")], release: release, stuck: [:trails_for])
    transit = FakeTransit.new(trips: { "a" => minutes(30) })
    elevation = FakeElevation.new
    departure = SATURDAY.in_time_zone("America/Los_Angeles")
    start = lambda do
      StationSearch.start(STATION, departure, transit: transit, hiking: hiking, elevation: elevation, noise: quiet_unknown, cache: cache)
    end

    first = start.call
    assert_same first, start.call
    release.set
    Timeout.timeout(5) { sleep 0.01 until first.events_since(0).last }
    events, done = first.events_since(0)
    assert done
    assert_equal [:checking, :trails, :update, :done], events.map(&:first)

    kept = start.call
    refute_same first, kept
    assert_equal [[:trails, ["a"]], [:done, ["a"]]], kept.events_since(0).first.map { |event, payload|
      [event, (payload.respond_to?(:trails) ? payload.trails : payload).map(&:name)]
    }
    assert_equal 1, hiking.batches.size
    travel StationSearch::KEEP + 1.minute
    Timeout.timeout(5) { sleep 0.01 until start.call.events_since(0).last }
    assert_equal 2, hiking.batches.size
  ensure
    release&.set
  end

  test "a search goes on in the background when the visitor leaves, and is kept for the next" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    transit = FakeTransit.new(trips: { "a" => minutes(30), "b" => minutes(30) })
    hiking = FakeHiking.new([trail("a"), trail("b")])
    assert_raises(IOError) do
      stub_const(TrailsService, :BATCH_SIZE, 1) do
        search(transit: transit, hiking: hiking) { |event, _| raise IOError, "gone" if event == :trails }
      end
    end
    Timeout.timeout(5) { sleep 0.01 while StationSearch::RUNNING.keys.any? { |key| key.include?(hiking) } }

    events = []
    result = search(transit: transit, hiking: hiking) { |event, _| events << event }
    assert_equal %w[a b], result.trails.map(&:name).sort
    assert_equal [:place, :trails], events
    assert_equal 2, hiking.batches.size
  ensure
    Rails.cache = original
  end

  test "a search says it's still going while nothing changes for a while" do
    release = Concurrent::Event.new
    events = []
    Thread.new { sleep 0.8; release.set }
    stub_const(TrailsService, :KEEP_ALIVE_SECONDS, 0.1) do
      search(transit: FakeTransit.new(trips: { "a" => minutes(30) }), hiking: FakeHiking.new([trail("a")], release: release, stuck: [:trails_for])) { |event, _| events << event }
    end
    assert_includes events, :waiting
    assert_equal :update, events.last
  ensure
    release&.set
  end

  # Starts the station's search for Saturday, running it at once rather than in the background.
  def station_search(hiking, transit: FakeTransit.new(trips: %w[a b c].to_h { |name| [name, minutes(30)] }), departure: SATURDAY,
    noise: quiet_unknown, **options)
    @station_cache ||= ActiveSupport::Cache::MemoryStore.new
    StationSearch.start(STATION, departure.in_time_zone("America/Los_Angeles"), transit: transit, hiking: hiking,
      elevation: FakeElevation.new, noise: noise, cache: @station_cache,
      **{ pool: station_pool, background_pool: station_pool }.merge(options))
  end

  # Runs searches at once, saying how many wait for it.
  def station_pool
    @station_pool ||= Class.new(Concurrent::ImmediateExecutor) { attr_accessor :queue_length }.new.tap { |pool| pool.queue_length = 0 }
  end

  # The routes a search shows, by name, and whether it ran rather than being kept.
  def shown(search)
    events = search.events_since(0).first
    [events.select { |event, _| event == :trails }.flat_map(&:last).map(&:name).sort, events.any? { |event, _| event == :checking }]
  end

  test "a kept search is served at once, and searched again in the background once it's half a day old" do
    a, b = trail("a"), trail("b")
    assert_equal [["a"], true], shown(station_search(FakeHiking.new([a])))
    both = FakeHiking.new([a, b])
    travel 1.hour
    assert_equal [["a"], false], shown(station_search(both))
    assert_empty both.batches

    # Half a day on, the kept search shows at once, while the station is searched again for later visits.
    travel 11.hours + 1.minute
    assert_equal [["a"], false], shown(station_search(both))
    assert_equal 1, both.batches.size
    assert_equal [%w[a b], false], shown(station_search(both))
  end

  test "a search that couldn't check every route is searched again ten minutes on, keeping the routes it found" do
    a, b, c = trail("a"), trail("b"), trail("c")
    assert_equal [%w[a b], true], shown(station_search(FakeHiking.new([a, b, c], failing: [c.osm_id])))
    travel 5.minutes
    assert_equal [%w[a b], false], shown(station_search(FakeHiking.new([a, b, c], failing: [b.osm_id])))
    travel 6.minutes
    # This time b couldn't be checked, but the last search found it.
    again = FakeHiking.new([a, b, c], failing: [b.osm_id])
    assert_equal [%w[a b], false], shown(station_search(again))
    assert_equal 3, again.batches.size
    assert_equal [%w[a b c], false], shown(station_search(again))
  end

  test "a search that couldn't check every route doesn't bring back routes it found too loud, nor ones too loud now" do
    a, b, c = trail("a"), trail("b"), trail("c")
    down = FakeNoise.new(failure: SearchErrors::UpstreamError.new("The noise map is down"))
    assert_equal [%w[a b], true], shown(station_search(FakeHiking.new([a, b, c], failing: [c.osm_id]), noise: down))
    travel 11.minutes
    # Searched again, b is beside a highway, and c still can't be checked.
    loud = FakeNoise.new({ "a" => { quiet: 0.9, typical: 0, loudest: 45 }, "b" => { quiet: 0.0, typical: 60, loudest: 70 } })
    hiking = FakeHiking.new([a, b, c], failing: [c.osm_id])
    assert_equal [%w[a b], false], shown(station_search(hiking, noise: loud))
    assert_equal [%w[a], false], shown(station_search(hiking, noise: loud))
    # Nor does a search that couldn't check it, once it's known to be.
    travel 11.minutes
    unchecked = FakeHiking.new([a, b, c], failing: [b.osm_id, c.osm_id])
    shown(station_search(unchecked, noise: loud))
    assert_equal [%w[a], false], shown(station_search(unchecked, noise: loud))
    kept = station_search(unchecked, noise: loud).events_since(0).first.find { |event, _| event == :trails }.last
    assert_equal [{ quiet: 0.9, typical: 0, loudest: 45 }], kept.map(&:noise)

    # Kept searches show without hikes that aren't shown now, as one kept from before the rule.
    key = StationSearch.keys(STATION, SATURDAY.in_time_zone("America/Los_Angeles"))[:day]
    entry = @station_cache.read(key)
    entry[:result].trails.first.noise = { quiet: 0.2, typical: 50, loudest: 60 }
    @station_cache.write(key, entry)
    assert_equal [[], false], shown(station_search(unchecked, noise: loud))
  end

  # A pool that holds what's posted to it until it's run.
  class HeldPool
    include Concurrent::ExecutorService

    def post(*args, &task)
      (@tasks ||= []) << -> { task.call(*args) }
      true
    end

    def run
      @tasks.shift.call while @tasks.present?
    end
  end

  test "a station's search a visitor waits on goes ahead of background work, and searching again runs in the background" do
    priorities = Concurrent::Array.new
    transit = FakeTransit.new(trips: { "a" => minutes(30) })
    transit.define_singleton_method(:rail_stations) { |**options| priorities << ProviderSlots.priority && super(**options) }
    background = HeldPool.new
    visit = -> { ProviderSlots.with_priority(ProviderSlots::VISITOR) { station_search(FakeHiking.new([trail("a")]), transit: transit, background_pool: background) } }
    assert_equal [["a"], true], shown(visit.call)
    assert_equal [ProviderSlots::SEARCH], priorities

    # Half a day on, the kept search shows at once, and the station is searched again behind searches visitors wait on.
    travel 12.hours + 1.minute
    assert_equal [["a"], false], shown(visit.call)
    assert_equal [ProviderSlots::SEARCH], priorities
    background.run
    assert_equal [ProviderSlots::SEARCH, ProviderSlots::BACKGROUND], priorities
  end

  test "a search still waiting for the background pool starts at once when a visitor waits on it, and runs once" do
    providers = { transit: FakeTransit.new(trips: { "a" => minutes(30) }), hiking: FakeHiking.new([trail("a")]),
      elevation: FakeElevation.new, noise: quiet_unknown }
    cache = ActiveSupport::Cache::MemoryStore.new
    background = HeldPool.new
    start = lambda do |pool|
      StationSearch.start(STATION, SATURDAY.in_time_zone("America/Los_Angeles"), fresh: true, cache: cache, pool: pool,
        background_pool: background, **providers)
    end
    # As when keeping the guide cities' searches ready.
    ready = start.(background)
    refute ready.started?
    assert_equal ProviderSlots::BACKGROUND, ready.provider_priority

    waited_on = ProviderSlots.with_priority(ProviderSlots::VISITOR) { start.(Concurrent::ImmediateExecutor.new) }
    assert_same ready, waited_on
    assert_equal ProviderSlots::SEARCH, waited_on.provider_priority
    assert_equal [["a"], true], shown(waited_on)
    background.run
    assert_equal 1, providers[:hiking].batches.size
  end

  test "with fresh, as for guides, kept searches are only used while they're recent and complete" do
    a, b = trail("a"), trail("b")
    station_search(FakeHiking.new([a]))
    hiking = FakeHiking.new([a, b])
    assert_equal [["a"], false], shown(station_search(hiking, fresh: true))
    travel 12.hours + 1.minute
    assert_equal [%w[a b], true], shown(station_search(hiking, fresh: true))

    station_search(FakeHiking.new([a, b], failing: [b.osm_id]), departure: SATURDAY + 1.day)
    assert_equal [%w[a b], true], shown(station_search(FakeHiking.new([a, b]), departure: SATURDAY + 1.day, fresh: true))
  end

  test "a station not yet searched for the day shows its search from a week before, moved to the day, while it's searched" do
    a, b = trail("a"), trail("b")
    assert_equal [["a"], true], shown(station_search(FakeHiking.new([a])))
    travel 7.days
    later = FakeHiking.new([a, b])
    moved = station_search(later, departure: SATURDAY + 7.days)
    assert_equal [["a"], false], shown(moved)
    trail = moved.events_since(0).first.first.last.sole
    # The last trip back left before dark that day, at 7:29 PM.
    assert_equal [SATURDAY + 7.days + 30.minutes, Time.utc(2026, 10, 4, 2, 29), Time.utc(2026, 10, 4, 1, 44)],
      [trail.arrival, trail.last_return, trail.sunset]
    assert_equal SATURDAY + 7.days, moved.events_since(0).first.last.last.departure_time
    # The day itself was searched meanwhile, for the next visitor.
    assert_equal 1, later.batches.size
    assert_equal [%w[a b], false], shown(station_search(later, departure: SATURDAY + 7.days))
    # With fresh, a week before doesn't count.
    assert_equal [%w[a b], true], shown(station_search(FakeHiking.new([a, b]), departure: SATURDAY + 14.days, fresh: true))
  end

  test "a search moved a week on leaves out the hikes the shorter days leave too little daylight for" do
    zone = ActiveSupport::TimeZone["America/Los_Angeles"]
    # From 8:30 AM, 20.8 miles take until 6:54 PM: before sunset at 6:58 PM, but not a week on, when it's at 6:44 PM.
    long, short = trail("long", length: 20.8), trail("short")
    [long, short].each { |route| route.arrival, route.sunset = SATURDAY + 30.minutes, Time.utc(2026, 9, 27, 1, 58) }
    result = TrailsService::Result.new(departure_time: SATURDAY.in_time_zone(zone), trails: [long, short], complete: true,
      returns_checked: true)
    moved = StationSearch.moved(result, (SATURDAY + 7.days).in_time_zone(zone))
    assert_equal [["short"], Time.utc(2026, 10, 4, 1, 44)], [moved.trails.map(&:name), moved.trails.sole.sunset]
  end

  test "searches in the background wait for a quiet pool, and a station isn't tried again soon after it fails" do
    a = trail("a")
    station_search(FakeHiking.new([a]))
    travel 12.hours + 1.minute
    busy = FakeHiking.new([a])
    @station_pool.queue_length = StationSearch::MAX_WAITING
    station_search(busy)
    assert_empty busy.tile_requests

    @station_pool.queue_length = 0
    down = FakeHiking.new(SearchErrors::UpstreamError.new("down"))
    assert_equal [["a"], false], shown(station_search(down))
    assert_equal 1, down.tile_requests.size
    # The kept search still shows, and the station isn't searched again for ten minutes.
    station_search(down)
    assert_equal 1, down.tile_requests.size
    travel 10.minutes + 1.second
    station_search(down)
    assert_equal 2, down.tile_requests.size
  end

  test "a station's search that can't start isn't left for others to wait on" do
    pool = Concurrent::FixedThreadPool.new(1).tap(&:shutdown)
    pool.wait_for_termination(5)
    hiking = FakeHiking.new([trail("a")])
    departure = SATURDAY.in_time_zone("America/Los_Angeles")
    start = lambda do |with|
      StationSearch.start(STATION, departure, transit: FakeTransit.new(trips: { "a" => minutes(30) }), hiking: hiking,
        elevation: FakeElevation.new, noise: quiet_unknown, cache: ActiveSupport::Cache::MemoryStore.new, pool: with)
    end
    assert_raises(Concurrent::RejectedExecutionError) { start.(pool) }
    assert_empty StationSearch::RUNNING.keys.select { |key| key.include?(hiking) }
    assert_equal [["a"], true], shown(start.(Concurrent::ImmediateExecutor.new))
  end

  test "only the US guide cities that have a guide have their searches kept ready" do
    directory = Pathname(Dir.mktmpdir("guides"))
    GuideService.directory = directory
    assert_empty SearchWarmer.cities
    # New York's guide is published, and Boston's and Chicago's aren't yet; Europe's cities aren't kept ready.
    %w[new-york-city london].each do |slug|
      directory.join("#{slug}.json").write(JSON.generate(guide_data.merge(slug: slug)))
    end
    assert_equal ["new-york-city"], SearchWarmer.cities.map(&:slug)
  ensure
    GuideService.directory = nil
  end

  test "the guide cities' stations are searched one at a time for the weekend, kept ready, and failures don't stop the rest" do
    guide = Struct.new(:name, :place, :time_zone)
    guides = [guide.new("Seattle", Place.new(latitude: 47.6, longitude: -122.3), "America/Los_Angeles"),
      guide.new("Down", Place.new(latitude: 1, longitude: 1), "UTC")]
    transit = Class.new do
      def major_stations(origin:, departure_time:)
        raise SearchErrors::UpstreamError, "down" if origin.latitude == 1

        [STATION, EASTSIDE]
      end
    end.new
    started = []
    searches = Class.new do
      define_method(:start) do |station, departure, fresh:, transit:, pool:|
        started << [station.name, departure.strftime("%a %-l %p"), fresh, pool]
        StationSearch.finished(TrailsService::Result.new(trails: []))
      end
    end.new
    log = StringIO.new
    count = SearchWarmer.warm(guides: guides, transit: transit, searches: searches, log: Logger.new(log), wait: 1)

    assert_equal 4, count
    # They run in the background, behind searches visitors wait on.
    background = Rails.configuration.x.background_pool
    assert_equal [["King Street", "Sat 8 AM", true, background], ["Eastside", "Sat 8 AM", true, background],
      ["King Street", "Sun 8 AM", true, background], ["Eastside", "Sun 8 AM", true, background]], started
    assert_equal 2, log.string.scan("Searches from Down for").size
  end

  test "routes are shown without highlights when they cannot be looked up" do
    transit = FakeTransit.new(trips: { "loop" => minutes(10) })
    result = search(transit: transit, hiking: FakeHiking.new([trail("loop")], highlights: SearchErrors::UpstreamError.new("busy")))
    assert_equal [[]], result.trails.map(&:highlights)
  end
end
