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
