require "test_helper"
require_relative "search_test_support"

class TransitousServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  DEPARTURE = Time.iso8601("2026-09-23T08:00:00-07:00")

  def origin
    Place.new(latitude: 47.6, longitude: -122.3)
  end

  def destination(latitude: 47.5)
    OverpassService::Trail.new(name: "Loop", latitude: latitude, longitude: -122.0)
  end

  def trips(connection, destinations: [destination, destination(latitude: 47.4)], departure_time: DEPARTURE, cache: Rails.cache)
    TransitousService.trips(origin: origin, destinations: destinations, departure_time: departure_time,
      connection: connection, cache: cache)
  end

  def trip(connection)
    TransitousService.trip(origin: origin, destination: destination, departure_time: DEPARTURE, connection: connection)
  end

  def areas
    [{ "name" => "United States", "adminLevel" => 2 }, { "name" => "Washington", "adminLevel" => 4 },
      { "name" => "Seattle", "adminLevel" => 8, "default" => true }]
  end

  test "an area reports its time zone and a readable name" do
    connection = stub_connection(:get, [{ "tz" => "America/Los_Angeles", "areas" => areas }]) do |request|
      assert_equal "47.60000,-122.30000", request.params["place"]
    end
    assert_equal({ time_zone: "America/Los_Angeles", area: "Seattle, Washington, United States" },
      TransitousService.area(47.6, -122.3, connection: connection))
  end

  test "unusable areas and time zones are left out" do
    [nil, 5, "", "../../etc/passwd", "America/Los Angeles"].each do |zone|
      area = TransitousService.area(47.6, -122.3, connection: stub_connection(:get, [{ "tz" => zone }]))
      assert_equal({ time_zone: nil, area: nil }, area)
    end
    assert_equal({ time_zone: nil, area: nil }, TransitousService.area(47.6, -122.3, connection: stub_connection(:get, [])))
    assert_raises(SearchErrors::UpstreamError) do
      TransitousService.area(47.6, -122.3, connection: stub_connection(:get, {}, status: 500))
    end
  end

  def station(id: "king-street", latitude: 47.598, longitude: -122.33)
    Station.new(name: "King Street", latitude: latitude, longitude: longitude, id: id)
  end

  # A stop as the map lists it.
  def map_stop(name, latitude, longitude, importance, modes: ["REGIONAL_RAIL"])
    { "name" => name, "stopId" => name.parameterize, "lat" => latitude, "lon" => longitude, "importance" => importance,
      "modes" => modes }
  end

  # A train on line that leaves at 8 AM and stops at each [latitude, longitude,
  # minutes later] in turn, ending at the last.
  def departure(line, *stops)
    leaves = Time.utc(2026, 9, 23, 15)
    following = stops.map do |latitude, longitude, minutes|
      { "lat" => latitude, "lon" => longitude, "arrival" => (leaves + minutes.minutes).iso8601 }
    end
    { "place" => { "departure" => leaves.iso8601 }, "routeId" => line, "nextStops" => following, "tripTo" => following.last }
  end

  # Answers the map's stops, and each stop's departures by its id; a stop
  # whose departures are an exception can't be looked up.
  def station_connections(stops, boards, requests = [])
    map = stub_connection(:get, lambda { |request|
      requests << [:stops, request.params.slice("min", "max", "modes", "grouped")]
      stops.respond_to?(:call) ? stops.call(request) : stops
    })
    times = stub_connection(:get, lambda { |request|
      requests << [:board, request.params["stopId"]]
      board = boards.fetch(request.params["stopId"], [])
      raise board if board.is_a?(Exception)

      { "stopTimes" => board }
    })
    [map, times]
  end

  def major_stations(stops, boards, requests = [], cache: ActiveSupport::Cache::MemoryStore.new, origin: self.origin)
    map, times = station_connections(stops, boards, requests)
    TransitousService.major_stations(origin: origin, departure_time: DEPARTURE, stops: map, boards: times, cache: cache)
  end

  # Seattle's stations: Everett and Tacoma are 40 km out, and Northgate is ten minutes up the line from King Street.
  def seattle_boards
    {
      "king-street" => [departure("north", [47.65, -122.32, 10], [47.98, -122.2, 60]), departure("south", [47.25, -122.44, 50])],
      "northgate" => [departure("north", [47.98, -122.2, 50]), departure("north", [47.598, -122.33, 10])],
      "eastside" => [departure("east", [47.61, -121.7, 45])],
      # Its trains end within the city.
      "waterfront" => [departure("waterfront", [47.66, -122.4, 20])]
    }
  end

  def seattle_stops
    [
      map_stop("KING STREET", 47.598, -122.33, 1.0), map_stop("King Street Hall 2", 47.5985, -122.3305, 0.95),
      map_stop("Northgate", 47.65, -122.32, 0.8), map_stop("Eastside", 47.61, -122.2, 0.5),
      map_stop("Waterfront", 47.605, -122.34, 0.4), map_stop("Small Halt", 47.62, -122.31, 0.1),
      map_stop("Bus Depot", 47.6, -122.31, 0.9, modes: ["BUS"]),
      # In the map's square, but over 10 km away.
      map_stop("Corner", 47.68, -122.41, 0.9)
    ]
  end

  test "searches start from the busiest and nearest train stations, each adding lines the others don't" do
    requests = []
    stations = major_stations(seattle_stops, seattle_boards, requests)

    assert_equal [Station.new(name: "King Street", latitude: 47.598, longitude: -122.33, id: "king-street"),
      Station.new(name: "Eastside", latitude: 47.61, longitude: -122.2, id: "eastside")], stations
    # Northgate's trains are King Street's, ten minutes on, and Waterfront's only go across the city.
    assert_equal [[:board, "king-street"], [:board, "northgate"], [:board, "waterfront"], [:board, "eastside"]],
      requests.select { |kind, _| kind == :board }
    stops = requests.find { |kind, _| kind == :stops }.last
    assert_equal ["47.50956,-122.43412", "47.69044,-122.16588", TransitousService::TRAIN_MODES.join(","), "true"],
      stops.values_at("min", "max", "modes", "grouped")
  end

  test "a station the trains of a chosen one reach quickly is chosen when enough of its trains are on other lines" do
    boards = seattle_boards.merge("northgate" => [departure("north", [47.98, -122.2, 50]),
      departure("north", [47.98, -122.2, 55]), departure("express", [48.2, -122.3, 40])])
    assert_equal ["King Street", "Northgate", "Eastside"], major_stations(seattle_stops, boards).map(&:name)

    # One train in five on another line is too few.
    boards["northgate"].push(departure("north", [47.98, -122.2, 70]), departure("north", [47.98, -122.2, 75]))
    assert_equal ["King Street", "Eastside"], major_stations(seattle_stops, boards).map(&:name)
  end

  test "stations farther out are looked for when none are near, and there are at most six" do
    requests = []
    # Tukwila is 16 km away, outside the first square.
    near_none = lambda do |request|
      Float(request.params["min"].split(",").first) > 47.45 ? [] : [map_stop("Tukwila", 47.46, -122.24, 0.6)]
    end
    stations = major_stations(near_none, { "tukwila" => [departure("south", [47.25, -122.44, 30])] }, requests)
    assert_equal ["Tukwila"], stations.map(&:name)
    assert_equal 2, requests.count { |kind, _| kind == :stops }

    # Eight stations 2 km apart around the origin, whose trains don't reach each other.
    stops = (0...8).map { |index| map_stop("Station #{index}", 47.6 + 0.018 * Math.cos(index), -122.3 + 0.027 * Math.sin(index), 1.0) }
    boards = stops.to_h { |stop| [stop["stopId"], [departure("line #{stop['stopId']}", [48.2, -122.3, 60])]] }
    assert_equal 6, major_stations(stops, boards).size
  end

  test "a place's stations are shared for days, unless some station's trains couldn't be looked up" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      requests = []
      major_stations(seattle_stops, seattle_boards, requests, cache: cache)
      major_stations(seattle_stops, seattle_boards, requests, cache: cache, origin: Place.new(latitude: 47.601, longitude: -122.301))
      assert_equal 1, requests.count { |kind, _| kind == :stops }
      travel 7.days + 1.minute
      major_stations(seattle_stops, seattle_boards, requests, cache: cache)
      assert_equal 2, requests.count { |kind, _| kind == :stops }

      # Without Northgate's trains, it's left out, since King Street's trains reach it quickly, and Eastside isn't.
      cache = ActiveSupport::Cache::MemoryStore.new
      failing = seattle_boards.merge("northgate" => SearchErrors::UpstreamError.new("down"),
        "eastside" => SearchErrors::UpstreamError.new("down"))
      assert_equal ["King Street", "Eastside"], major_stations(seattle_stops, failing, cache: cache).map(&:name)
      requests = []
      major_stations(seattle_stops, seattle_boards, requests, cache: cache)
      assert_equal 1, requests.count { |kind, _| kind == :stops }
    end
  end

  test "without the map of stations, there are no stations to start from" do
    map = stub_connection(:get, {}, status: 500)
    times = stub_connection(:get, {}) { flunk "No request expected" }
    assert_raises(SearchErrors::UpstreamError) do
      TransitousService.major_stations(origin: origin, departure_time: DEPARTURE, stops: map, boards: times,
        cache: ActiveSupport::Cache::MemoryStore.new)
    end
  end

  test "stations are named as people know them" do
    {
      "HOBOKEN" => "Hoboken", "SECAUCUS LOWER LEVEL" => "Secaucus Lower Level", "Ny Moynihan Train Hall At Penn Station" => "Penn Station",
      "Paris Gare de Lyon Hall 1 - 2" => "Paris Gare de Lyon", "S+U Alexanderplatz Bhf (Berlin)" => "Alexanderplatz",
      "Berlin Hbf (tief)" => "Berlin Hbf", "MÜNCHEN OST" => "München Ost", "Zürich HB" => "Zürich HB", nil => "Station", " " => "Station"
    }.each { |name, known| assert_equal known, TransitousService.station_name(name) }
  end

  def rail_stations(connection, cache: ActiveSupport::Cache::MemoryStore.new, station: self.station)
    TransitousService.rail_stations(origin: station, departure_time: DEPARTURE, connection: connection, cache: cache)
  end

  test "rail stations are those trains reach from the station, quickest first" do
    requests = []
    all = [
      reached_stop(47.598, -122.33, 0, rides: 0, id: "king-street"), reached_stop(47.65, -122.35, 18, id: "north"),
      reached_stop(47.2, -122.4, 40, id: "tacoma"), reached_stop(47.9, -122.2, 70.0, rides: 2, id: "everett"),
      reached_stop(47.3, -122.2, 20, modes: ["BUS"], id: "bus"), reached_stop(47.65, -122.35, 25, rides: 2, id: "north")
    ]
    connection = stub_connection(:get, { "all" => all }) { |request| requests << request.params }
    assert_equal [[47.65, -122.35, 18], [47.2, -122.4, 40], [47.9, -122.2, 70.0]], rail_stations(connection)

    trains = TransitousService::TRAIN_MODES.join(",")
    assert_equal [{ "one" => "king-street", "time" => "2026-09-23T15:00:00Z", "maxTravelTime" => "210", "transitModes" => trains }],
      requests
    assert_includes trains.split(","), "REGIONAL_RAIL"
    assert_includes trains.split(","), "SUBURBAN"
    # Transitous's RAIL takes the subway too, and METRO is its old name for suburban trains.
    assert_empty trains.split(",") & %w[RAIL METRO SUBWAY TRAM BUS COACH]

    rail_stations(connection, station: station(id: nil))
    assert_equal "47.5980000,-122.3300000", requests.last["one"]
  end

  test "where a station's trains reach too many stations to list, those within 120 or 80 minutes are, and the limit that fits is remembered" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      limits = []
      connection = stub_connection(:get, lambda { |request|
        limits << request.params["maxTravelTime"]
        raise SearchErrors::ResponseTooLarge unless request.params["maxTravelTime"] == "80"

        { "all" => [reached_stop(48.0, -122.0, 70)] }
      })
      assert_equal [[48.0, -122.0, 70]], rail_stations(connection, cache: cache)
      assert_equal %w[210 120 80], limits

      rail_stations(connection, cache: cache, station: station(id: "nearby", latitude: 47.62))
      assert_equal %w[210 120 80 80], limits
      travel 1.day + 1.minute
      rail_stations(connection, cache: cache, station: station(id: "another"))
      assert_equal %w[210 120 80 80 210 120 80], limits

      too_many = stub_connection(:get, {}) { raise SearchErrors::ResponseTooLarge }
      assert_raises(SearchErrors::UpstreamError) { rail_stations(too_many) }
    end
  end

  test "rail stations are shared for hours by searches from the same station at the same time, and failures aren't" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      connection = stub_connection(:get, { "all" => [reached_stop(48.0, -122.0, 20)] }) { calls += 1 }
      2.times { rail_stations(connection, cache: cache) }
      assert_equal 1, calls
      rail_stations(connection, cache: cache, station: station(id: "another"))
      assert_equal 2, calls
      travel 6.hours + 1.minute
      rail_stations(connection, cache: cache)
      assert_equal 3, calls

      failing = stub_connection(:get, {}, status: 500) { calls += 1 }
      2.times { assert_raises(SearchErrors::UpstreamError) { rail_stations(failing, cache: cache, station: station(id: "down")) } }
      assert_equal 5, calls
    end
  end

  test "reachable stops skip malformed entries, and a list must be one" do
    body = { "all" => [
      reached_stop(47.61, -122.33, 12, modes: ["BUS"], id: "3rd-ave"),
      reached_stop(47.5, -122.0, 95.0, rides: 2, modes: ["SUBURBAN", "BUS"]),
      reached_stop(47.4, -122.1, 40, modes: "REGIONAL_RAIL", id: "x" * 201),
      reached_stop(91, 0, 5), reached_stop(47.5, -122.0, -1), reached_stop(47.5, -122.0, 5, rides: "1"),
      { "place" => nil, "duration" => 5, "k" => 1 }, nil
    ] }
    stops = TransitousService.reachable(stub_connection(:get, body), {})
    assert_equal [
      { key: "3rd-ave", latitude: 47.61, longitude: -122.33, minutes: 12, rides: 1, train: false },
      { key: [47.5, -122.0], latitude: 47.5, longitude: -122.0, minutes: 95.0, rides: 2, train: true },
      { key: [47.4, -122.1], latitude: 47.4, longitude: -122.1, minutes: 40, rides: 1, train: true }
    ], stops
    [{}, { "all" => nil }, []].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) { TransitousService.reachable(stub_connection(:get, invalid), {}) }
    end
  end

  test "trips more than half a day ahead are shared for hours, and the day's for minutes" do
    travel_to Time.utc(2026, 9, 22, 12) do
      assert_equal 6.hours, TransitousService.trip_cache_ttl(Time.utc(2026, 9, 23, 0, 1))
      assert_equal 15.minutes, TransitousService.trip_cache_ttl(Time.utc(2026, 9, 22, 23, 59))
    end
  end

  test "the latest way back from every destination takes one request that arrives by the deadline" do
    deadline = Time.iso8601("2026-09-23T23:00:00-07:00")
    body = {
      "transit_durations" => [[{ "duration" => 16_740.0, "transfers" => 1 }, { "duration" => 18_000.0, "transfers" => 0 }], [], []],
      "street_durations" => [{}, {}, { "duration" => 1_200.0 }]
    }
    connection = stub_connection(:get, body) do |request|
      assert_equal "47.6000000;-122.3000000", request.params["one"]
      assert_equal "47.5000000;-122.0000000,47.4000000;-122.0000000,47.3000000;-122.0000000", request.params["many"]
      assert_equal ["2026-09-24T06:00:00Z", "true"], request.params.values_at("time", "arriveBy")
      assert_equal "780", request.params["maxTravelTime"]
      assert_equal ["1800", "1800"], request.params.values_at("maxPreTransitTime", "maxPostTransitTime")
    end
    latest = TransitousService.latest_returns(origin: origin, deadline: deadline, earliest_return: deadline - 13.hours,
      destinations: [destination, destination(latitude: 47.4), destination(latitude: 47.3)], connection: connection)
    assert_equal [Time.iso8601("2026-09-23T18:21:00-07:00"), nil, Time.iso8601("2026-09-23T22:40:00-07:00")], latest
    assert_equal [], TransitousService.latest_returns(origin: origin, destinations: [], deadline: deadline,
      earliest_return: deadline, connection: stub_connection(:get, {}) { flunk "No request expected" })
    ["invalid", {}, { "transit_durations" => [[], []] }, { "transit_durations" => [[{ "duration" => -1, "transfers" => 0 }]] }].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) do
        TransitousService.latest_returns(origin: origin, destinations: [destination], deadline: deadline,
          earliest_return: deadline - 1.hour, connection: stub_connection(:get, invalid))
      end
    end
  end

  def leg(mode, **fields)
    { "mode" => mode, "startTime" => "2026-09-23T15:30:00Z", "endTime" => "2026-09-23T17:02:00Z", **fields }
  end

  def itinerary(start, finish, legs)
    { "duration" => (Time.iso8601(finish) - Time.iso8601(start)).to_i, "transfers" => [legs.size - 1, 0].max,
      "startTime" => start, "endTime" => finish, "legs" => legs }
  end

  test "a journey there lists the legs on transit of the soonest arrival, trains by their lines' names" do
    amtrak = leg("REGIONAL_RAIL", "routeShortName" => "", "routeLongName" => "Amtrak Cascades", "displayName" => "516",
      "agencyName" => "Amtrak", "headsign" => "Vancouver", "from" => { "stopId" => "king-street", "name" => "King  Street" },
      "to" => { "stopId" => "mount-vernon", "name" => "Mount Vernon" }, "startTime" => "2026-09-23T15:40:00Z",
      "endTime" => "2026-09-23T16:55:00-07:00")
    commuter = leg("SUBURBAN", "routeShortName" => "MNBNP", "routeLongName" => "Port Jervis Line", "agencyName" => "NJ Transit",
      "from" => { "stopId" => "a,b" }, "to" => { "name" => "No id" })
    unnamed = leg("RAIL", "routeShortName" => "", "routeLongName" => " ", "displayName" => "8811")
    bus = leg("BUS", "routeShortName" => "206", "routeLongName" => "Route 206", "agencyName" => "Skagit  Transit", "headsign" => nil)
    body = { "itineraries" => [
      itinerary("2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z",
        [leg("WALK"), amtrak, commuter, unnamed, leg("WALK"), bus, leg("WALK")]),
      itinerary("2026-09-23T15:40:00Z", "2026-09-23T18:10:00Z", [leg("BUS", "routeShortName" => "90X")])
    ], "direct" => [] }
    connection = stub_connection(:get, body) do |request|
      assert_equal ["47.6000000,-122.3000000", "47.5000000,-122.0000000", "2026-09-23T15:00:00Z", "false"],
        request.params.values_at("fromPlace", "toPlace", "time", "arriveBy")
      # Every trip over the next three hours, so later trains that arrive as soon are among them.
      assert_equal ["true", "10800"], request.params.values_at("timetableView", "searchWindow")
      # By train, with the subway or light rail to reach it, and the walk from the start as long as the one to the end.
      assert_equal TransitousService::TRIP_MODES.join(","), request.params["transitModes"]
      assert_equal ["1800", "1800"], request.params.values_at("maxPreTransitTime", "maxPostTransitTime")
    end
    times = { departure: "2026-09-23T15:30:00Z", arrival: "2026-09-23T17:02:00Z" }
    assert_equal({ departure: "2026-09-23T15:19:00Z", arrival: "2026-09-23T17:31:00Z", legs: [
      # Each leg's stops are named, and its times are in UTC.
      { mode: "REGIONAL_RAIL", name: "Amtrak Cascades", agency: "Amtrak", headsign: "Vancouver",
        from: "king-street", to: "mount-vernon", from_name: "King Street", to_name: "Mount Vernon",
        departure: "2026-09-23T15:40:00Z", arrival: "2026-09-23T23:55:00Z" },
      # Stop ids that couldn't be sent back to the planner are left out.
      { mode: "SUBURBAN", name: "Port Jervis Line", agency: "NJ Transit", headsign: nil, from: nil, to: nil,
        from_name: nil, to_name: "No id", **times },
      { mode: "RAIL", name: "8811", agency: nil, headsign: nil, from: nil, to: nil, from_name: nil, to_name: nil, **times },
      { mode: "BUS", name: "206", agency: "Skagit Transit", headsign: nil, from: nil, to: nil, from_name: nil, to_name: nil, **times }
    ] }, TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE, connection: connection))
  end

  test "a journey there leaves as late as it can and still arrives soonest" do
    train = ->(name) { leg("REGIONAL_RAIL", "routeLongName" => name) }
    body = { "itineraries" => [
      # The 8:03 waits an hour at a transfer for the train the 9:10 makes.
      itinerary("2026-09-23T15:03:00Z", "2026-09-23T18:12:00Z", [train.("Coast"), train.("Main"), train.("Port Jervis")]),
      itinerary("2026-09-23T16:10:00Z", "2026-09-23T18:12:00Z", [train.("Corridor"), train.("Main"), train.("Port Jervis")]),
      itinerary("2026-09-23T17:10:00Z", "2026-09-23T19:40:00Z", [train.("Corridor"), train.("Port Jervis")])
    ], "direct" => [] }
    there = TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE,
      connection: stub_connection(:get, body), cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal ["2026-09-23T16:10:00Z", "2026-09-23T18:12:00Z"], there.values_at(:departure, :arrival)
  end

  # A trip back on a bus or a train between two stops, leaving and arriving at
  # these UTC times: in the afternoon or evening of September 23, or early on September 24.
  def trip_back(leave, home, mode: "BUS", name: "206", from: nil, to: nil)
    leave, home = [leave, home].map { |time| "2026-09-#{time >= '12:00' ? 23 : 24}T#{time}:00Z" }
    itinerary(leave, home, [leg(mode, "routeShortName" => name, "from" => { "stopId" => from }.compact,
      "to" => { "stopId" => to }.compact)])
  end

  # A journey there riding 2 h 20 min: the city bus to the station, then two trains.
  def journey_there
    { departure: "2026-09-23T15:10:00Z", arrival: "2026-09-23T17:30:00Z", legs: [
      { mode: "BUS", name: "7", from: "home-stop", to: "downtown" },
      { mode: "REGIONAL_RAIL", name: "Sounder", from: "king-street", to: "tacoma" },
      { mode: "SUBURBAN", name: "Link", from: "tacoma", to: "lakewood" }
    ] }
  end

  def ways_back(connection, like: journey_there, earliest: Time.utc(2026, 9, 23, 21), cache: ActiveSupport::Cache::MemoryStore.new)
    TransitousService.ways_back(origin: destination, destination: origin, like: like, earliest: earliest,
      deadline: Time.iso8601("2026-09-23T23:00:00-07:00"), connection: connection, cache: cache)
  end

  # A stop with a name and coordinates, as plans list them.
  def stop(name, latitude, longitude = -122.0)
    { "name" => name, "lat" => latitude, "lon" => longitude }
  end

  test "a ride at either end of a trip is walked instead when the walk is short and gets there about as soon" do
    # The train reaches the station at 7:55, and a bus gets home at 8:15, a kilometer away: 18 minutes' walk.
    train = leg("REGIONAL_RAIL", "routeLongName" => "Hudson", "from" => stop("Cold Spring", 47.5), "to" => stop("Station", 47.0),
      "startTime" => "2026-09-24T01:52:00Z", "endTime" => "2026-09-24T02:55:00Z")
    bus = leg("BUS", "routeShortName" => "B62", "from" => stop("Jackson Av", 47.0005), "to" => stop("44 Dr", 47.0085),
      "startTime" => "2026-09-24T03:03:00Z", "endTime" => "2026-09-24T03:10:00Z")
    home_by_bus = ->(arrival) { itinerary("2026-09-24T01:52:00Z", arrival, [leg("WALK"), train, leg("WALK"), bus, leg("WALK")]) }
    summary = ->(trip, to) { TransitousService.journey_summary(trip, [47.5, -122.0], [to, -122.0]) }

    walked = summary.(home_by_bus.("2026-09-24T03:15:00Z"), 47.009)
    assert_equal [["Hudson"], "2026-09-24T03:13:00Z"], [walked[:legs].pluck(:name), walked[:arrival]]
    # Walking 37 minutes is too far, and walking home 15 minutes after a quick bus is too late.
    assert_equal %w[Hudson B62], summary.(home_by_bus.("2026-09-24T03:15:00Z"), 47.02)[:legs].pluck(:name)
    assert_equal %w[Hudson B62], summary.(home_by_bus.("2026-09-24T02:58:00Z"), 47.009)[:legs].pluck(:name)

    # Setting out, walking 18 minutes to the train beats a bus that leaves 7 minutes earlier.
    first_bus = leg("BUS", "routeShortName" => "B62", "from" => stop("44 Dr", 47.0085), "to" => stop("Jackson Av", 47.0005),
      "startTime" => "2026-09-23T15:05:00Z", "endTime" => "2026-09-23T15:12:00Z")
    out = leg("REGIONAL_RAIL", "routeLongName" => "Hudson", "from" => stop("Station", 47.0), "to" => stop("Cold Spring", 47.5),
      "startTime" => "2026-09-23T15:30:00Z", "endTime" => "2026-09-23T16:35:00Z")
    there = TransitousService.journey_summary(itinerary("2026-09-23T15:05:00Z", "2026-09-23T16:40:00Z", [first_bus, out]),
      [47.009, -122.0], [47.5, -122.0])
    assert_equal [["Hudson"], "2026-09-23T15:12:00Z"], [there[:legs].pluck(:name), there[:departure]]
    # A trip's only ride is kept.
    only_bus = itinerary("2026-09-23T15:05:00Z", "2026-09-23T15:12:00Z", [first_bus])
    assert_equal ["B62"], TransitousService.journey_summary(only_bus, [47.009, -122.0], [47.0, -122.0])[:legs].pluck(:name)

    # Rides stay where walking would get home after the deadline, or leave before the trips asked for.
    late = TransitousService.journey_summary(home_by_bus.("2026-09-24T03:15:00Z"), [47.5, -122.0], [47.009, -122.0],
      arrive_by: Time.utc(2026, 9, 24, 3, 12))
    assert_equal %w[Hudson B62], late[:legs].pluck(:name)
    later_bus = first_bus.merge("startTime" => "2026-09-23T15:15:00Z", "endTime" => "2026-09-23T15:22:00Z")
    early = TransitousService.journey_summary(itinerary("2026-09-23T15:15:00Z", "2026-09-23T16:40:00Z", [later_bus, out]),
      [47.009, -122.0], [47.5, -122.0], leave_after: Time.utc(2026, 9, 23, 15, 15))
    assert_equal %w[B62 Hudson], early[:legs].pluck(:name)
  end

  test "trips walk a stretch rather than ride only a few minutes sooner" do
    ride = ->(name, mode = "REGIONAL_RAIL") { leg(mode, "routeShortName" => name) }
    body = { "itineraries" => [
      # Leaving at 01:00, a bus from the station gets home 8 minutes sooner than walking: not worth a ride.
      itinerary("2026-09-24T01:00:00Z", "2026-09-24T02:20:00Z", [ride.("walk home")]),
      itinerary("2026-09-24T01:00:00Z", "2026-09-24T02:12:00Z", [ride.("bus home"), ride.("40", "BUS")]),
      # Leaving at 02:00, the subway saves 15 minutes: worth it.
      itinerary("2026-09-24T02:00:00Z", "2026-09-24T03:30:00Z", [ride.("late walk")]),
      itinerary("2026-09-24T02:00:00Z", "2026-09-24T03:15:00Z", [ride.("late subway"), ride.("7", "SUBWAY")])
    ], "direct" => [] }
    ways = ways_back(stub_connection(:get, body), like: nil, earliest: Time.utc(2026, 9, 24, 0, 30))
    assert_equal [["walk home"], ["late subway", "7"]], ways[:trips].map { |trip| trip[:legs].pluck(:name) }
    assert_equal ["walk home", "late subway"], [ways[:back], ways[:last]].map { |trip| trip[:legs].first[:name] }
  end

  test "a journey there goes by train where one arrives in time to hike, and otherwise on any transit" do
    requests = []
    # The planner looks further ahead when nothing goes by train that day.
    next_day = { "itineraries" => [itinerary("2026-09-24T15:10:00Z", "2026-09-24T17:00:00Z", [leg("REGIONAL_RAIL",
      "routeShortName" => "tomorrow")])], "direct" => [] }
    today = { "itineraries" => [itinerary("2026-09-23T15:10:00Z", "2026-09-23T16:40:00Z", [leg("BUS", "routeShortName" => "40")])],
      "direct" => [] }
    connection = stub_connection(:get, lambda { |request|
      requests << request.params["transitModes"]
      request.params["transitModes"] ? next_day : today
    })
    journey = TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE, connection: connection,
      cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal ["40"], journey[:legs].pluck(:name)
    assert_equal [TransitousService::TRIP_MODES.join(","), nil], requests
  end

  test "ways back go by train where one leaves after the hike, otherwise on any transit, and never on another day" do
    requests = []
    by_train = { "itineraries" => [trip_back("01:00", "03:00", mode: "REGIONAL_RAIL", name: "during the hike"),
      # The planner looks further back when nothing gets home that evening.
      itinerary("2026-09-22T20:00:00Z", "2026-09-22T22:00:00Z", [leg("REGIONAL_RAIL", "routeShortName" => "yesterday")])],
      "direct" => [] }
    any = { "itineraries" => [trip_back("02:30", "04:00", name: "bus after the hike")], "direct" => [] }
    connection = stub_connection(:get, lambda { |request|
      requests << request.params["transitModes"]
      request.params["transitModes"] ? by_train : any
    })
    ways = ways_back(connection, like: nil, earliest: Time.utc(2026, 9, 24, 2))
    assert_equal ["bus after the hike"], ways[:trips].map { |trip| trip[:legs].sole[:name] }
    assert_equal [TransitousService::TRIP_MODES.join(","), nil], requests

    yesterday = stub_connection(:get, { "itineraries" => by_train["itineraries"].drop(1), "direct" => [] })
    assert_nil ways_back(yesterday, like: nil, earliest: Time.utc(2026, 9, 24, 2))[:back]
    # Where nothing leaves after the hike, the last trip that evening is still the way back, home before it's over.
    before = stub_connection(:get, { "itineraries" => [trip_back("00:30", "02:00")], "direct" => [] })
    assert_equal "2026-09-24T00:30:00Z", ways_back(before, like: nil, earliest: Time.utc(2026, 9, 24, 3))[:back][:departure]
  end

  test "the timetable there goes by train unless asked not to" do
    requests = []
    body = { "itineraries" => [itinerary("2026-09-23T15:10:00Z", "2026-09-23T16:40:00Z", [leg("BUS", "routeShortName" => "40")])],
      "direct" => [] }
    connection = stub_connection(:get, body) { |request| requests << request.params["transitModes"] }
    trips = TransitousService.departures(origin: origin, destination: destination, time: DEPARTURE, latest: DEPARTURE + 2.hours,
      by_train: false, connection: connection, cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal [["40"], [nil]], [trips.map { |trip| trip[:legs].sole[:name] }, requests]
    assert TransitousService.by_train?({ legs: [{ mode: "SUBWAY" }, { mode: "REGIONAL_RAIL" }] })
    refute TransitousService.by_train?({ legs: [{ mode: "REGIONAL_RAIL" }, { mode: "BUS" }] })

    # The train reaches a station 18 minutes' walk from the route at 16:20, and a bus gets there at 16:30.
    train = leg("REGIONAL_RAIL", "routeShortName" => "Sounder", "to" => stop("Station", 47.491),
      "startTime" => "2026-09-23T15:10:00Z", "endTime" => "2026-09-23T16:20:00Z")
    bus = leg("BUS", "routeShortName" => "40", "from" => stop("Station", 47.4911), "to" => stop("Trailhead", 47.4995),
      "startTime" => "2026-09-23T16:24:00Z", "endTime" => "2026-09-23T16:30:00Z")
    body = { "itineraries" => [itinerary("2026-09-23T15:10:00Z", "2026-09-23T16:30:00Z", [train, bus])], "direct" => [] }
    rides = lambda do |arrive_by|
      TransitousService.departures(origin: origin, destination: destination, time: DEPARTURE, latest: DEPARTURE + 2.hours,
        arrive_by: arrive_by, connection: stub_connection(:get, body), cache: ActiveSupport::Cache::MemoryStore.new)
        .sole[:legs].pluck(:name)
    end
    # Walking from the station gets there at 16:38, so the bus is only walked instead when that's in time.
    assert_equal ["Sounder"], rides.(nil)
    assert_equal %w[Sounder 40], rides.(Time.utc(2026, 9, 23, 16, 35))
  end

  test "the way back rides the journey's trains back from where they stopped to where they started, home soonest after the hike" do
    body = { "itineraries" => [
      trip_back("00:10", "02:00", name: "after the hike"),
      trip_back("00:40", "02:00", name: "later, just as soon home"),
      # Home soonest, but leaving before the hike is over.
      trip_back("00:00", "01:50", name: "before the hike ends"),
      trip_back("04:00", "05:50", name: "the last one"),
      trip_back("04:00", "05:30", name: "the last one, sooner home"),
      trip_back("05:00", "06:30", name: "too late")
    ], "direct" => [] }
    requests = []
    connection = stub_connection(:get, body) { |request| requests << request.params }
    ways = ways_back(connection, earliest: Time.utc(2026, 9, 24, 0, 5))

    assert_equal ["later, just as soon home", "the last one, sooner home", true],
      [ways[:back][:legs].sole[:name], ways[:last][:legs].sole[:name], ways[:same_way]]
    # The timetable back runs from the first trip home after the hike to the last, one trip for each time it leaves.
    assert_equal ["later, just as soon home", "the last one, sooner home"], ways[:trips].map { |trip| trip[:legs].sole[:name] }
    params = requests.sole
    assert_equal ["47.5000000,-122.0000000", "47.6000000,-122.3000000", "2026-09-24T06:00:00Z", "true", "true"],
      params.values_at("fromPlace", "toPlace", "time", "arriveBy", "timetableView")
    # From the end of the hike until the deadline, and walks of up to half an hour at either end.
    assert_equal ["21300", "1800", "1800"], params.values_at("searchWindow", "maxPreTransitTime", "maxPostTransitTime")
    assert_equal "lakewood,king-street", params["via"]
    assert_equal "BUS,REGIONAL_RAIL,SUBURBAN,SUBWAY,TRAM", params["transitModes"]
  end

  test "without a train there, only the kinds of transit keep the way back, and without a journey there, it's any way" do
    # Buses stop across the street on the way back, so their stops aren't kept.
    ferry = { departure: "2026-09-23T15:10:00Z", arrival: "2026-09-23T17:30:00Z", legs: [
      { mode: "BUS", name: "7", from: "home-stop", to: "pier" }, { mode: "FERRY", name: "Bainbridge", from: "pier", to: "island" }
    ] }
    requests = []
    connection = stub_connection(:get, { "itineraries" => [trip_back("01:00", "03:00")], "direct" => [] }) do |request|
      requests << request.params.slice("via", "transitModes")
    end
    assert ways_back(connection, like: ferry)[:same_way]
    walk = { departure: "2026-09-23T15:10:00Z", arrival: "2026-09-23T15:40:00Z", legs: [] }
    assert_nil ways_back(connection, like: walk)[:same_way]
    assert_nil ways_back(connection, like: nil)[:same_way]
    by_train = { "transitModes" => TransitousService::TRIP_MODES.join(",") }
    assert_equal [{ "transitModes" => "BUS,FERRY,SUBWAY,TRAM" }, by_train, by_train], requests
  end

  test "trips back that ride much longer than the trip there don't count, so a slow same way gives way to a quicker one" do
    # 2 h 20 min there allows up to 3 h 10 min back.
    requests = []
    connection = stub_connection(:get, lambda { |request|
      requests << request.params["via"]
      itineraries = if request.params["via"]
        [trip_back("00:10", "03:30", name: "slow bus the same way"), trip_back("22:00", "00:00", name: "before the hike")]
      else
        [trip_back("01:00", "03:10", name: "quicker another way"), trip_back("02:00", "05:20", name: "slow and last")]
      end
      { "itineraries" => itineraries, "direct" => [] }
    })
    ways = ways_back(connection, earliest: Time.utc(2026, 9, 24, 0, 5))
    assert_equal ["quicker another way", "quicker another way", false],
      [ways[:back][:legs].sole[:name], ways[:last][:legs].sole[:name], ways[:same_way]]
    assert_equal ["lakewood,king-street", nil], requests

    # When every way back is slow, the quickest of them still shows.
    slow = stub_connection(:get, { "itineraries" => [trip_back("00:30", "05:00", name: "slow")], "direct" => [] })
    assert_equal "slow", ways_back(slow, earliest: Time.utc(2026, 9, 24, 0, 5))[:back][:legs].sole[:name]
  end

  test "a slow trip after the hike beats quick ones that leave before it's over" do
    connection = stub_connection(:get, lambda { |request|
      itineraries = if request.params["via"]
        [trip_back("18:00", "20:00", name: "the same way, before the hike ends")]
      else
        [trip_back("18:30", "20:30", name: "quick, before the hike ends"), trip_back("21:00", "00:20", name: "slow, after the hike")]
      end
      { "itineraries" => itineraries, "direct" => [] }
    })
    ways = ways_back(connection, earliest: Time.utc(2026, 9, 23, 20))
    assert_equal ["slow, after the hike", "slow, after the hike", false],
      [ways[:back][:legs].sole[:name], ways[:last][:legs].sole[:name], ways[:same_way]]
  end

  test "where the same way doesn't get home in time, or the planner doesn't know its stops, any way back does" do
    [{ "itineraries" => [], "direct" => [] }, nil].each do |same_way|
      requests = []
      connection = stub_connection(:get, lambda { |request|
        requests << request.params["via"]
        raise Faraday::BadRequestError, "unknown stop" if request.params["via"] && same_way.nil?

        request.params["via"] ? same_way : { "itineraries" => [trip_back("03:00", "05:00", name: "another way")], "direct" => [] }
      })
      ways = ways_back(connection)
      assert_equal ["another way", "another way", false], [ways[:back][:legs].sole[:name], ways[:last][:legs].sole[:name], ways[:same_way]]
      assert_equal ["lakewood,king-street", nil], requests
    end

    nothing = ways_back(stub_connection(:get, { "itineraries" => [], "direct" => [] }))
    assert_equal({ back: nil, last: nil, same_way: false, trips: [] }, nothing)
    assert_raises(SearchErrors::UpstreamError) { ways_back(stub_connection(:get, {}, status: 503)) }
  end

  test "trips back from a route's far end go any way, quick enough for the trip there" do
    requests = []
    body = { "itineraries" => [trip_back("01:00", "05:30", name: "slow"), trip_back("02:00", "03:30", name: "quick"),
      trip_back("04:00", "05:50", name: "last")], "direct" => [] }
    connection = stub_connection(:get, body) { |request| requests << request.params }
    ways = TransitousService.ways_back(origin: destination, destination: origin, like: journey_there, follow: false,
      earliest: Time.utc(2026, 9, 24, 0, 30), deadline: Time.iso8601("2026-09-23T23:00:00-07:00"), connection: connection,
      cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal [%w[quick last], nil], [ways[:trips].map { |trip| trip[:legs].sole[:name] }, ways[:same_way]]
    assert_equal [nil, TransitousService::TRIP_MODES.join(",")], requests.sole.values_at("via", "transitModes")
  end

  test "the trips there that leave in a window are listed in order, without slow ones or later arrivals at the same time" do
    requests = []
    body = { "itineraries" => [
      itinerary("2026-09-23T16:10:00Z", "2026-09-23T17:40:00Z", [leg("SUBURBAN", "routeLongName" => "Hudson Line")]),
      itinerary("2026-09-23T15:10:00Z", "2026-09-23T16:30:00Z", [leg("SUBURBAN", "routeLongName" => "Hudson Line")]),
      itinerary("2026-09-23T15:10:00Z", "2026-09-23T16:50:00Z", [leg("BUS", "routeShortName" => "99")]),
      # Riding much longer than the quickest, and leaving after the window.
      itinerary("2026-09-23T15:40:00Z", "2026-09-23T19:00:00Z", [leg("BUS", "routeShortName" => "slow")]),
      itinerary("2026-09-23T19:10:00Z", "2026-09-23T20:30:00Z", [leg("SUBURBAN", "routeLongName" => "Hudson Line")])
    ], "direct" => [] }
    connection = stub_connection(:get, body) { |request| requests << request.params }
    trips = TransitousService.departures(origin: origin, destination: destination, time: DEPARTURE,
      latest: Time.utc(2026, 9, 23, 19), connection: connection, cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal [%w[2026-09-23T15:10:00Z 2026-09-23T16:30:00Z], %w[2026-09-23T16:10:00Z 2026-09-23T17:40:00Z]],
      trips.map { |trip| trip.values_at(:departure, :arrival) }
    assert_equal ["false", "true", "14400"], requests.sole.values_at("arriveBy", "timetableView", "searchWindow")
  end

  test "when no way back leaves after the hike, the way back is the last one the same way, and ways back are cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, { "itineraries" => [trip_back("01:00", "03:00")], "direct" => [] }) { calls += 1 }
    2.times do
      ways = ways_back(connection, earliest: Time.utc(2026, 9, 24, 2), cache: cache)
      assert_equal [ways[:last], true], [ways[:back], ways[:same_way]]
      assert_equal "2026-09-24T01:00:00Z", ways[:back][:departure]
    end
    # The same way, then any way by train, then on any transit, each asked once.
    assert_equal 3, calls
  end

  test "walking the whole way is a journey without legs, and no journey is nil" do
    walk = itinerary("2026-09-23T15:00:00Z", "2026-09-23T15:20:00Z", [leg("WALK")])
    assert_equal({ departure: "2026-09-23T15:00:00Z", arrival: "2026-09-23T15:20:00Z", legs: [] },
      TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE,
        connection: stub_connection(:get, { "itineraries" => [], "direct" => [walk] })))
    malformed = [{ "legs" => "none" }, walk.merge("startTime" => "bad"), walk.merge("endTime" => "2026-09-23T14:00:00Z"),
      { "startTime" => "2026-09-23T15:00:00Z" }]
    assert_nil TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE,
      connection: stub_connection(:get, { "itineraries" => malformed, "direct" => [] }))
    ["invalid", {}, { "itineraries" => nil, "direct" => [] }].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) do
        TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE, connection: stub_connection(:get, invalid))
      end
    end
  end

  test "trips to every destination take one request and use the fastest way" do
    body = {
      "transit_durations" => [[{ "duration" => 2700.0, "transfers" => 0 }, { "duration" => 2400.0, "transfers" => 1 }], []],
      "street_durations" => [{ "duration" => 3000.0 }, {}]
    }
    connection = stub_connection(:get, body) do |request|
      assert_equal "47.6000000;-122.3000000", request.params["one"]
      assert_equal "47.5000000;-122.0000000,47.4000000;-122.0000000", request.params["many"]
      assert_equal "2026-09-23T15:00:00Z", request.params["time"]
      assert_equal "240", request.params["maxTravelTime"]
      assert_equal "1800", request.params["maxPostTransitTime"]
      assert_nil request.params["transitModes"]
    end
    assert_equal [{ duration: 2400.0, transfers: 1 }, nil], trips(connection)
  end

  test "trips can keep to some kinds of transit, and are cached apart from others" do
    cache = ActiveSupport::Cache::MemoryStore.new
    modes = []
    connection = stub_connection(:get, { "transit_durations" => [[], []] }) { |request| modes << request.params["transitModes"] }
    TransitousService.trips(origin: origin, destinations: [destination, destination(latitude: 47.4)], departure_time: DEPARTURE,
      modes: TransitousService::CITY_MODES, connection: connection, cache: cache)
    trips(connection, cache: cache)
    assert_equal ["SUBWAY,TRAM", nil], modes
  end

  test "walking the whole way wins when it is fastest" do
    body = { "transit_durations" => [[{ "duration" => 2400.0, "transfers" => 0 }]], "street_durations" => [{ "duration" => 900.0 }] }
    assert_equal [{ duration: 900.0, transfers: nil }], trips(stub_connection(:get, body), destinations: [destination])
    body.delete("street_durations")
    assert_equal [{ duration: 2400.0, transfers: 0 }], trips(stub_connection(:get, body), destinations: [destination])
  end

  test "no destinations need no request" do
    assert_equal [], trips(stub_connection(:get, {}) { flunk "No request expected" }, destinations: [])
  end

  test "invalid trip responses and API errors surface without provider details" do
    [
      "invalid", [], {}, { "transit_durations" => [[]] }, { "transit_durations" => [nil, []] },
      { "transit_durations" => [[{ "duration" => -1, "transfers" => 0 }], []] },
      { "transit_durations" => [[{ "duration" => 60, "transfers" => "1" }], []] },
      '{"transit_durations":[[{"duration":1e400,"transfers":0}],[]]}'
    ].each do |body|
      assert_raises(SearchErrors::UpstreamError) { trips(stub_connection(:get, body)) }
    end
    error = assert_raises(SearchErrors::UpstreamError) { trips(stub_connection(:get, { "error" => "private details" }, status: 422)) }
    refute_includes error.message, "private details"
  end

  test "trips are cached per origin destinations and departure time" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, { "transit_durations" => [[], []] }) { calls += 1 }
    2.times { assert_equal [nil, nil], trips(connection, cache: cache) }
    assert_equal 1, calls
    trips(connection, departure_time: DEPARTURE + 15.minutes, cache: cache)
    assert_equal 2, calls
  end

  test "planning one route departs at the chosen time and returns the fastest journey" do
    body = { "itineraries" => [{ "duration" => 2400, "transfers" => 1 }, { "duration" => 1800, "transfers" => 2 }], "direct" => [] }
    connection = stub_connection(:get, body) do |request|
      assert_equal "47.6000000,-122.3000000", request.params["fromPlace"]
      assert_equal "47.5000000,-122.0000000", request.params["toPlace"]
      assert_equal "2026-09-23T15:00:00Z", request.params["time"]
      assert_equal "false", request.params["arriveBy"]
      assert_equal "false", request.params["timetableView"]
      assert_equal "1800", request.params["maxPostTransitTime"]
    end
    assert_equal({ duration: 1800, transfers: 2 }, trip(connection))
  end

  test "planning counts direct walks and reports unreachable routes" do
    body = { "itineraries" => [{ "duration" => 2400, "transfers" => 0 }], "direct" => [{ "duration" => 600 }] }
    assert_equal({ duration: 600, transfers: nil }, trip(stub_connection(:get, body)))
    assert_nil trip(stub_connection(:get, { "itineraries" => [], "direct" => [] }))
    [{}, { "itineraries" => [{ "duration" => 60 }], "direct" => [] }, { "itineraries" => [nil], "direct" => [] }].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) { trip(stub_connection(:get, invalid)) }
    end
  end

  test "network failures and timeouts surface safely" do
    [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |error_type|
      connection = stub_connection(:get, {}) { raise error_type, "secret provider details" }
      error = assert_raises(SearchErrors::UpstreamError) { trips(connection) }
      refute_includes error.message, "secret provider details"
    end
  end

  test "invalid route coordinates are rejected before any request" do
    connection = stub_connection(:get, {}) { flunk "No request expected" }
    assert_raises(SearchErrors::InvalidInput) { trips(connection, destinations: [destination(latitude: 91)]) }
  end

  test "provider failures are never cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, {}, status: 503) { calls += 1 }
    2.times do
      assert_raises(SearchErrors::UpstreamError) { TransitousService.area(47.6, -122.3, connection: connection, cache: cache) }
      assert_raises(SearchErrors::UpstreamError) { trips(connection, cache: cache) }
    end
    assert_equal 4, calls
  end
end
