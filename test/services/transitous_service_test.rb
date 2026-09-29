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

  # Answers the stops transit reaches from the origin, and with transitModes,
  # those trains reach from each hub by its id.
  def rail_connection(hubs, rides, requests = [])
    stub_connection(:get, lambda { |request|
      requests << request.params.slice("one", "time", "maxTravelTime", "transitModes")
      raise SearchErrors::UpstreamError, "down" if rides[request.params["one"]].is_a?(Exception)

      { "all" => request.params["transitModes"] ? rides.fetch(request.params["one"]) : hubs }
    })
  end

  def rail_stations(connection, cache: ActiveSupport::Cache::MemoryStore.new, origin: self.origin)
    TransitousService.rail_stations(origin: origin, departure_time: DEPARTURE, connection: connection, cache: cache)
  end

  test "rail stations are those trains reach from the busiest stations transit reaches, timed from the origin" do
    hubs = [
      reached_stop(47.6, -122.33, 12, id: "king-street", importance: 0.5, modes: ["REGIONAL_RAIL", "BUS"]),
      reached_stop(47.62, -122.32, 5, id: "bus-stop", importance: 0.9, modes: ["BUS"]),
      # Next to King Street, so trains are boarded there only.
      reached_stop(47.601, -122.331, 14, id: "sounder", importance: 0.4),
      # King Street's trains get there within ten minutes of reaching it directly.
      reached_stop(47.65, -122.35, 20, rides: 2, id: "north", importance: 0.3),
      reached_stop(47.7, -122.4, 25, rides: 0, id: "local", importance: 0.01)
    ]
    rides = {
      "king-street" => [reached_stop(47.6, -122.33, 0, rides: 0, id: "king-street"),
        reached_stop(47.65, -122.35, 18, id: "north"), reached_stop(47.2, -122.4, 40, id: "tacoma"),
        reached_stop(47.9, -122.2, 70.0, rides: 2, id: "everett"), reached_stop(47.3, -122.2, 20, modes: ["BUS"], id: "bus")],
      "local" => [reached_stop(47.9, -122.2, 30, id: "everett"), reached_stop(48.7, -122.5, 120, id: "bellingham")]
    }
    requests = []
    stations = rail_stations(rail_connection(hubs, rides, requests))

    assert_equal [[47.65, -122.35, 30], [47.2, -122.4, 52], [47.9, -122.2, 55], [48.7, -122.5, 145]], stations
    trains = TransitousService::TRAIN_MODES.join(",")
    assert_equal [
      { "one" => "47.6000000,-122.3000000", "time" => "2026-09-23T15:00:00Z", "maxTravelTime" => "60" },
      { "one" => "king-street", "time" => "2026-09-23T15:12:00Z", "maxTravelTime" => "198", "transitModes" => trains },
      { "one" => "local", "time" => "2026-09-23T15:25:00Z", "maxTravelTime" => "185", "transitModes" => trains }
    ], requests
    assert_includes trains.split(","), "REGIONAL_RAIL"
    assert_includes trains.split(","), "SUBURBAN"
    # Transitous's RAIL takes the subway too, and METRO is its old name for suburban trains.
    assert_empty trains.split(",") & %w[RAIL METRO SUBWAY TRAM BUS COACH]
  end

  test "where a hub's trains reach too many stations to list, those within 120 or 80 minutes are, and the limit that fits is remembered" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      limits = []
      connection = stub_connection(:get, lambda { |request|
        next { "all" => [reached_stop(47.6, -122.33, 12, id: "hub")] } unless request.params["transitModes"]

        limits << request.params["maxTravelTime"]
        raise SearchErrors::ResponseTooLarge unless request.params["maxTravelTime"] == "80"

        { "all" => [reached_stop(48.0, -122.0, 70)] }
      })
      assert_equal [[48.0, -122.0, 82]], rail_stations(connection, cache: cache)
      assert_equal %w[198 120 80], limits

      rail_stations(connection, cache: cache, origin: Place.new(latitude: 47.64, longitude: -122.34))
      assert_equal %w[198 120 80 80], limits
      travel 1.day + 1.minute
      rail_stations(connection, cache: cache, origin: Place.new(latitude: 47.62, longitude: -122.31))
      assert_equal %w[198 120 80 80 198 120 80], limits

      too_many = rail_connection([reached_stop(47.6, -122.33, 12, id: "hub")], { "hub" => SearchErrors::ResponseTooLarge.new("huge") })
      assert_raises(SearchErrors::UpstreamError) { rail_stations(too_many) }
    end
  end

  test "trains are boarded at no more than three stations, and at their coordinates when they have no id" do
    hubs = [47.7, 47.8, 47.9, 48.0].each_with_index.map do |latitude, index|
      reached_stop(latitude, -122.3, 10 * (index + 1), importance: 1.0 / (index + 1))
    end
    requests = []
    connection = stub_connection(:get, lambda { |request|
      requests << request.params["one"]
      { "all" => request.params["transitModes"] ? [reached_stop(48.5, -121.0, 60)] : hubs }
    })
    assert_equal [[48.5, -121.0, 70]], rail_stations(connection)
    assert_equal ["47.6000000,-122.3000000", "47.7000000,-122.3000000", "47.8000000,-122.3000000", "47.9000000,-122.3000000"],
      requests
  end

  test "where every stop within an hour is too many to list, stations within 40 or 25 minutes are, and the list that fits is remembered" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      requests = []
      connection = stub_connection(:get, lambda { |request|
        requests << request.params["maxTravelTime"]
        next { "all" => [reached_stop(48.5, -121.0, 60)] } if request.params["transitModes"]
        raise SearchErrors::ResponseTooLarge unless request.params["maxTravelTime"] == "25"

        { "all" => [reached_stop(47.6, -122.33, 12, id: "king-street")] }
      })
      assert_equal [[48.5, -121.0, 72]], rail_stations(connection, cache: cache)
      assert_equal %w[60 40 25 198], requests

      # Nearby searches go straight to the list that fits, for a day.
      rail_stations(connection, cache: cache, origin: Place.new(latitude: 47.64, longitude: -122.34))
      assert_equal %w[60 40 25 198 25 198], requests
      travel 1.day + 1.minute
      rail_stations(connection, cache: cache)
      assert_equal %w[60 40 25 198 25 198 60 40 25 198], requests
    end
  end

  test "where even stations within 25 minutes are too many to list, there are none for a day" do
    calls = 0
    huge = stub_connection(:get, { "all" => [] }) do
      calls += 1
      raise SearchErrors::ResponseTooLarge
    end
    cache = ActiveSupport::Cache::MemoryStore.new
    assert_equal [], rail_stations(huge, cache: cache)
    assert_equal [], rail_stations(huge, cache: cache, origin: Place.new(latitude: 47.64, longitude: -122.34))
    assert_equal 3, calls
  end

  test "a hub whose trains can't be looked up is left out and the list isn't shared, and with no trains at all the search fails" do
    hubs = [reached_stop(47.6, -122.33, 12, id: "king-street", importance: 0.5),
      reached_stop(47.7, -122.4, 25, id: "north", importance: 0.1)]
    cache = ActiveSupport::Cache::MemoryStore.new
    requests = []
    connection = rail_connection(hubs, { "king-street" => SearchErrors::UpstreamError.new("down"),
      "north" => [reached_stop(48.0, -122.0, 20)] }, requests)
    assert_equal [[48.0, -122.0, 45]], rail_stations(connection, cache: cache)
    rail_stations(connection, cache: cache)
    assert_equal 6, requests.size

    connection = rail_connection(hubs, { "king-street" => SearchErrors::UpstreamError.new("down"),
      "north" => SearchErrors::UpstreamError.new("down") })
    assert_raises(SearchErrors::UpstreamError) { rail_stations(connection) }
    assert_raises(SearchErrors::UpstreamError) { rail_stations(stub_connection(:get, {}, status: 500)) }
  end

  test "rail stations are shared for hours by searches from about the same place at the same time" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      requests = []
      connection = rail_connection([reached_stop(47.6, -122.33, 12, id: "hub")], { "hub" => [reached_stop(48.0, -122.0, 20)] }, requests)
      rail_stations(connection, cache: cache)
      rail_stations(connection, cache: cache, origin: Place.new(latitude: 47.6004, longitude: -122.3004))
      assert_equal 2, requests.size
      rail_stations(connection, cache: cache, origin: Place.new(latitude: 47.61, longitude: -122.3))
      assert_equal 4, requests.size
      travel 6.hours + 1.minute
      rail_stations(connection, cache: cache)
      assert_equal 6, requests.size
    end
  end

  test "reachable stops skip malformed entries, and a list must be one" do
    body = { "all" => [
      reached_stop(47.61, -122.33, 12, modes: ["BUS"], id: "3rd-ave", importance: 0.2),
      reached_stop(47.5, -122.0, 95.0, rides: 2, modes: ["SUBURBAN", "BUS"], importance: "high"),
      reached_stop(47.4, -122.1, 40, modes: "REGIONAL_RAIL", id: "x" * 201),
      reached_stop(91, 0, 5), reached_stop(47.5, -122.0, -1), reached_stop(47.5, -122.0, 5, rides: "1"),
      { "place" => nil, "duration" => 5, "k" => 1 }, nil
    ] }
    stops = TransitousService.reachable(stub_connection(:get, body), {})
    assert_equal [
      { key: "3rd-ave", id: "3rd-ave", latitude: 47.61, longitude: -122.33, minutes: 12, rides: 1, importance: 0.2, train: false },
      { key: [47.5, -122.0], id: nil, latitude: 47.5, longitude: -122.0, minutes: 95.0, rides: 2, importance: 0, train: true },
      { key: [47.4, -122.1], id: nil, latitude: 47.4, longitude: -122.1, minutes: 40, rides: 1, importance: 0, train: true }
    ], stops
    [{}, { "all" => nil }, []].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) { TransitousService.reachable(stub_connection(:get, invalid), {}) }
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
      "agencyName" => "Amtrak", "headsign" => "Vancouver", "from" => { "stopId" => "king-street" },
      "to" => { "stopId" => "mount-vernon" })
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
      assert_nil request.params["maxPreTransitTime"]
    end
    assert_equal({ departure: "2026-09-23T15:19:00Z", arrival: "2026-09-23T17:31:00Z", legs: [
      { mode: "REGIONAL_RAIL", name: "Amtrak Cascades", agency: "Amtrak", headsign: "Vancouver",
        from: "king-street", to: "mount-vernon" },
      # Stop ids that couldn't be sent back to the planner are left out.
      { mode: "SUBURBAN", name: "Port Jervis Line", agency: "NJ Transit", headsign: nil, from: nil, to: nil },
      { mode: "RAIL", name: "8811", agency: nil, headsign: nil, from: nil, to: nil },
      { mode: "BUS", name: "206", agency: "Skagit Transit", headsign: nil, from: nil, to: nil }
    ] }, TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE, connection: connection))
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
    assert_equal [{ "transitModes" => "BUS,FERRY,SUBWAY,TRAM" }, {}, {}], requests
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
    assert_equal({ back: nil, last: nil, same_way: false }, nothing)
    assert_raises(SearchErrors::UpstreamError) { ways_back(stub_connection(:get, {}, status: 503)) }
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
    # The same way, then any way, each asked once.
    assert_equal 2, calls
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
