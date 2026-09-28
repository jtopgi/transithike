require "test_helper"
require_relative "search_test_support"

class TransitousServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  ARRIVAL = Time.iso8601("2026-09-23T12:30:00-07:00")

  def match(overrides = {})
    {
      "type" => "PLACE", "name" => "Pike Place Fish Market", "lat" => 47.6086, "lon" => -122.3407,
      "areas" => [
        { "name" => "United States", "adminLevel" => 2, "matched" => false },
        { "name" => "Washington", "adminLevel" => 4, "matched" => false },
        { "name" => "Seattle", "adminLevel" => 8, "matched" => true, "default" => true }
      ]
    }.merge(overrides)
  end

  def origin
    TransitousService::Location.new(latitude: 47.6, longitude: -122.3)
  end

  def destination(latitude: 47.5)
    OverpassService::Trail.new(name: "Loop", latitude: latitude, longitude: -122.0)
  end

  def transit(connection, arrival_time: ARRIVAL, cache: Rails.cache)
    TransitousService.transit_duration(
      origin: origin, destination: destination, arrival_time: arrival_time, connection: connection, cache: cache
    )
  end

  def journeys(itineraries: [], direct: [])
    { "itineraries" => itineraries.map { |duration| { "duration" => duration } },
      "direct" => direct.map { |duration| { "duration" => duration } } }
  end

  test "place search sends the query and maps the best match with a readable label" do
    connection = stub_connection(:get, [match("tz" => "America/Los_Angeles"), match("name" => "Other place")]) do |request|
      assert_equal "A & B / 東京", request.params["text"]
      assert_equal "1", request.params["numResults"]
      assert_equal "en", request.params["language"]
    end
    location = TransitousService.geocode("A & B / 東京", connection: connection)
    assert_equal 47.6086, location.latitude
    assert_equal(-122.3407, location.longitude)
    assert_equal "Pike Place Fish Market, Seattle, Washington, United States", location.name
    assert_equal "America/Los_Angeles", location.time_zone
  end

  test "unusable time zones are ignored" do
    [nil, 5, "", "../../etc/passwd", "America/Los Angeles"].each do |time_zone|
      location = TransitousService.geocode("Seattle", connection: stub_connection(:get, [match("tz" => time_zone)]))
      assert_nil location.time_zone
    end
  end

  test "labels skip blank duplicate and malformed names" do
    areas = [{ "name" => "Seattle", "default" => true }, nil, { "name" => 5, "adminLevel" => 2 },
      { "name" => "Washington", "adminLevel" => 4 }]
    assert_equal "Seattle, Washington", TransitousService.label(match("name" => " Seattle ", "areas" => areas))
    assert_nil TransitousService.label({ "name" => " ", "areas" => "invalid" })
  end

  test "unknown places are distinct from provider failures" do
    assert_nil TransitousService.geocode("unknown", connection: stub_connection(:get, []))
    ["invalid", {}, [nil], ["invalid"], [match("lat" => 91)], [match("lat" => "47.6")]].each do |body|
      assert_raises(SearchErrors::UpstreamError) do
        TransitousService.geocode("origin", connection: stub_connection(:get, body))
      end
    end
    error = assert_raises(SearchErrors::UpstreamError) do
      TransitousService.geocode("origin", connection: stub_connection(:get, { "error" => "private details" }, status: 500))
    end
    refute_includes error.message, "private details"
  end

  test "place search results are cached by normalized text" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, [match]) { calls += 1 }
    first = TransitousService.geocode("Pike  Place", connection: connection, cache: cache)
    assert_equal first, TransitousService.geocode(" pike place ", connection: connection, cache: cache)
    assert_equal 1, calls
  end

  test "routing asks for arrival by the chosen time and returns the fastest journey" do
    connection = stub_connection(:get, journeys(itineraries: [2400, 1800], direct: [2100])) do |request|
      assert_equal "47.6000000,-122.3000000", request.params["fromPlace"]
      assert_equal "47.5000000,-122.0000000", request.params["toPlace"]
      assert_equal "2026-09-23T19:30:00Z", request.params["time"]
      assert_equal "true", request.params["arriveBy"]
      assert_equal "false", request.params["timetableView"]
      assert_equal "false", request.params["detailedLegs"]
      assert_equal "1800", request.params["maxPostTransitTime"]
    end
    assert_equal 1800, transit(connection)
  end

  test "walking directly counts when it is faster and no journey means unreachable" do
    assert_equal 600, transit(stub_connection(:get, journeys(direct: [600])))
    assert_nil transit(stub_connection(:get, journeys))
  end

  test "invalid routing responses and API errors surface without provider details" do
    [
      "invalid", [], {}, { "itineraries" => [] }, { "itineraries" => nil, "direct" => [] },
      { "itineraries" => [nil], "direct" => [] }, { "itineraries" => [{}], "direct" => [] },
      journeys(itineraries: [-1]), journeys(direct: ["30"]),
      '{"itineraries":[{"duration":1e400}],"direct":[]}'
    ].each do |body|
      assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:get, body)) }
    end
    error = assert_raises(SearchErrors::UpstreamError) do
      transit(stub_connection(:get, { "error" => "private details" }, status: 422))
    end
    refute_includes error.message, "private details"
  end

  test "network failures and timeouts surface safely" do
    [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |error_type|
      connection = stub_connection(:get, {}) { raise error_type, "secret provider details" }
      error = assert_raises(SearchErrors::UpstreamError) { transit(connection) }
      refute_includes error.message, "secret provider details"
    end
  end

  test "invalid route coordinates are rejected before any request" do
    connection = stub_connection(:get, journeys) { flunk "No request expected" }
    assert_raises(SearchErrors::InvalidInput) do
      TransitousService.transit_duration(
        origin: origin, destination: destination(latitude: 91), arrival_time: ARRIVAL, connection: connection
      )
    end
  end

  test "routing results are cached per origin destination and arrival time" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, journeys) { calls += 1 }
    2.times { assert_nil transit(connection, cache: cache) }
    assert_equal 1, calls
    transit(connection, arrival_time: ARRIVAL + 15.minutes, cache: cache)
    assert_equal 2, calls
  end

  test "provider failures are never cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, {}, status: 503) { calls += 1 }
    2.times do
      assert_raises(SearchErrors::UpstreamError) { TransitousService.geocode("Seattle", connection: connection, cache: cache) }
      assert_raises(SearchErrors::UpstreamError) { transit(connection, cache: cache) }
    end
    assert_equal 4, calls
  end
end
