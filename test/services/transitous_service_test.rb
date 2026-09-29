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

  test "reachable stops list where transit goes and when, and which are stations, skipping malformed entries" do
    body = { "all" => [
      { "place" => { "lat" => 47.61, "lon" => -122.33, "name" => "3rd Ave", "modes" => ["BUS"] }, "duration" => 12, "k" => 1 },
      { "place" => { "lat" => 47.5, "lon" => -122.0, "modes" => ["REGIONAL_RAIL", "BUS"] }, "duration" => 95.0, "k" => 2 },
      { "place" => { "lat" => 47.4, "lon" => -122.1, "modes" => "FERRY" }, "duration" => 40, "k" => 1 },
      { "place" => { "lat" => 91, "lon" => 0 }, "duration" => 5, "k" => 1 },
      { "place" => { "lat" => 47.5, "lon" => -122.0 }, "duration" => -1, "k" => 1 },
      { "place" => { "lat" => 47.5, "lon" => -122.0 }, "duration" => 5, "k" => "1" },
      { "place" => nil, "duration" => 5, "k" => 1 }, nil
    ] }
    connection = stub_connection(:get, body) do |request|
      assert_equal "47.6000000,-122.3000000", request.params["one"]
      assert_equal "2026-09-23T15:00:00Z", request.params["time"]
      assert_equal "150", request.params["maxTravelTime"]
      assert_nil request.params["transitModes"]
    end
    assert_equal [[47.61, -122.33, 12, 1, false], [47.5, -122.0, 95.0, 2, true], [47.4, -122.1, 40, 1, true]],
      TransitousService.reachable_stops(origin: origin, departure_time: DEPARTURE, connection: connection)
    [{}, { "all" => nil }, []].each do |invalid|
      assert_raises(SearchErrors::UpstreamError) do
        TransitousService.reachable_stops(origin: origin, departure_time: DEPARTURE, connection: stub_connection(:get, invalid))
      end
    end
  end

  test "where every stop is too many to list, stops reached by rail and ferries are listed, and the list that fits is remembered" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      requests = []
      fits = ->(params) { params["transitModes"] && params["maxTravelTime"] == "90" }
      connection = stub_connection(:get, { "all" => [{ "place" => { "lat" => 47.5, "lon" => -122.0, "modes" => ["SUBURBAN"] },
        "duration" => 30, "k" => 1 }] }) do |request|
        requests << request.params.slice("maxTravelTime", "transitModes")
        raise SearchErrors::ResponseTooLarge unless fits.(request.params)
      end
      arguments = { origin: origin, departure_time: DEPARTURE, connection: connection, cache: cache }
      assert_equal [[47.5, -122.0, 30, 1, true]], TransitousService.reachable_stops(**arguments)
      modes = TransitousService::RAIL_MODES.join(",")
      assert_equal [{ "maxTravelTime" => "150" }, { "maxTravelTime" => "150", "transitModes" => modes },
        { "maxTravelTime" => "90", "transitModes" => modes }], requests
      assert_includes modes.split(","), "REGIONAL_RAIL"
      assert_includes modes.split(","), "FERRY"
      refute_includes modes.split(","), "BUS"

      # Nearby searches go straight to the list that fits, for a day.
      TransitousService.reachable_stops(**arguments, origin: Place.new(latitude: 47.64, longitude: -122.34))
      assert_equal 4, requests.size
      travel 1.day + 1.minute
      TransitousService.reachable_stops(**arguments)
      assert_equal 7, requests.size
    end
  end

  test "where even rail stops are too many to list, searches go without the list for a day" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      huge = stub_connection(:get, { "all" => [] }) do
        calls += 1
        raise SearchErrors::ResponseTooLarge
      end
      arguments = { origin: origin, departure_time: DEPARTURE, connection: huge, cache: cache }
      assert_nil TransitousService.reachable_stops(**arguments)
      assert_nil TransitousService.reachable_stops(**arguments, origin: Place.new(latitude: 47.64, longitude: -122.34))
      assert_equal 3, calls

      travel 1.day + 1.minute
      assert_nil TransitousService.reachable_stops(**arguments)
      assert_equal 6, calls
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

  test "a journey there lists the legs on transit of the soonest arrival" do
    amtrak = leg("REGIONAL_RAIL", "routeShortName" => "", "routeLongName" => "Amtrak Cascades", "displayName" => "516",
      "agencyName" => "Amtrak", "headsign" => "Vancouver")
    bus = leg("BUS", "routeShortName" => "206", "routeLongName" => "Route 206", "agencyName" => "Skagit  Transit", "headsign" => nil)
    body = { "itineraries" => [
      itinerary("2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z", [leg("WALK"), amtrak, leg("WALK"), bus, leg("WALK")]),
      itinerary("2026-09-23T15:40:00Z", "2026-09-23T18:10:00Z", [leg("BUS", "routeShortName" => "90X")])
    ], "direct" => [] }
    connection = stub_connection(:get, body) do |request|
      assert_equal ["47.6000000,-122.3000000", "47.5000000,-122.0000000", "2026-09-23T15:00:00Z", "false"],
        request.params.values_at("fromPlace", "toPlace", "time", "arriveBy")
      assert_nil request.params["maxPreTransitTime"]
    end
    assert_equal({ departure: "2026-09-23T15:19:00Z", arrival: "2026-09-23T17:31:00Z", legs: [
      { mode: "REGIONAL_RAIL", name: "Amtrak Cascades", agency: "Amtrak", headsign: "Vancouver" },
      { mode: "BUS", name: "206", agency: "Skagit Transit", headsign: nil }
    ] }, TransitousService.journey(origin: origin, destination: destination, time: DEPARTURE, connection: connection))
  end

  test "a journey back leaves as late as possible and arrives by the deadline" do
    deadline = Time.iso8601("2026-09-23T23:00:00-07:00")
    body = { "itineraries" => [
      itinerary("2026-09-24T01:23:00Z", "2026-09-24T04:21:00Z", [leg("BUS", "routeShortName" => "206")]),
      itinerary("2026-09-24T02:30:00Z", "2026-09-24T06:05:00Z", [leg("BUS", "routeShortName" => "late")]),
      itinerary("2026-09-23T23:00:00Z", "2026-09-24T02:00:00Z", [leg("BUS", "routeShortName" => "early")])
    ], "direct" => [] }
    connection = stub_connection(:get, body) do |request|
      assert_equal ["2026-09-24T06:00:00Z", "true", "1800"], request.params.values_at("time", "arriveBy", "maxPreTransitTime")
    end
    journey = TransitousService.journey(origin: destination, destination: origin, time: deadline, arrive_by: true, connection: connection)
    assert_equal ["2026-09-24T01:23:00Z", "2026-09-24T04:21:00Z", "206"], [journey[:departure], journey[:arrival], journey[:legs].sole[:name]]
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
      assert_equal "180", request.params["maxTravelTime"]
      assert_equal "1800", request.params["maxPostTransitTime"]
    end
    assert_equal [{ duration: 2400.0, transfers: 1 }, nil], trips(connection)
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
