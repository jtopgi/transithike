require "test_helper"
require_relative "search_test_support"

class OverpassServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  def fetch(elements, lat: 47.0, &block)
    connection = stub_connection(:post, { "elements" => elements }, &block)
    OverpassService.get_trails(lat: lat, lon: -122.0, connection: connection)
  end

  # A straight route of the given length in miles, starting at the origin.
  def route_of(miles, id: 123)
    route = route_element(id: id)
    route["members"].first["geometry"].last["lat"] = 47.0 + miles * 1609.344 / 111_195
    route
  end

  test "maps geometry to miles, route start, source link and bounded query" do
    route = route_element
    route["center"] = { "lat" => 0, "lon" => 0 }
    route["tags"]["website"] = "javascript:alert(1)"
    trail = fetch([route]) do |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      assert_includes query, "(around:25000,47.0,-122.0)"
      assert_includes query, '["route"="hiking"]'
      assert_includes query, "[timeout:20]"
      assert_includes query, "[maxsize:8388608]"
      assert_includes query, "out geom 100;"
    end.first
    assert_equal "Forest Loop", trail.name
    assert_equal "A wooded walk", trail.summary
    assert_equal 47.0, trail.latitude
    assert_equal(-122.0, trail.longitude)
    assert_in_delta 0.691, trail.length, 0.001
    assert_equal 123, trail.osm_id
    assert_equal [[[47.0, -122.0], [47.01, -122.0]]], trail.path
    assert_in_delta 0, trail.distance, 0.001
    assert_nil trail.duration
  end

  test "reports distance from the origin in miles" do
    trail = fetch([route_element], lat: 47.01).first
    assert_in_delta 0.691, trail.distance, 0.001
  end

  test "route previews are downsampled but keep every way's ends" do
    route = route_element
    route["members"].first["geometry"] = (0..400).map { |step| { "lat" => 47.0 + step * 0.0001, "lon" => -122.0 } }
    path = fetch([route]).first.path
    assert_equal 1, path.size
    assert_operator path.first.size, :<=, OverpassService::PREVIEW_POINTS + 1
    assert_equal [47.0, -122.0], path.first.first
    assert_equal [47.04, -122.0], path.first.last
  end

  test "deduplicates member ways and honors backward orientation" do
    route = route_element
    route["members"].first["role"] = "backward"
    route["members"] << route["members"].first.dup
    trail = fetch([route]).first
    assert_in_delta 0.691, trail.length, 0.001
    assert_equal 47.01, trail.latitude
  end

  test "leaves out multi-day routes longer than 30 miles" do
    assert_equal [123], fetch([route_of(29.9), route_of(30.1, id: 124)]).map(&:osm_id)
    assert_equal [], fetch([])
  end

  test "skips incomplete geometry nested relations and routes without measurable length" do
    missing = route_element
    missing["members"].first.delete("geometry")
    partial = route_element
    partial["members"].first["geometry"] << nil
    nested = route_element
    nested["members"] << { "type" => "relation", "ref" => 99 }
    zero = route_element
    zero["members"].first["geometry"].last["lat"] = 47.0
    assert_empty fetch([missing, partial, nested, zero])
  end

  test "uses honest unnamed route fallback" do
    route = route_element
    route["tags"].delete("name")
    route["tags"].delete("description")
    trail = fetch([route]).first
    assert_equal "Unnamed hiking route", trail.name
    assert_includes trail.summary, "OpenStreetMap"
  end

  test "bounds candidates and picks the closest mapped starting points" do
    routes = (1..120).map { |id| route_element(id: id, latitude: 47.0 + (120 - id) * 0.001) }
    trails = fetch(routes)
    assert_equal OverpassService::MAX_TRANSIT_ROUTES, trails.size
    assert_equal 100, trails.first.osm_id
    assert_equal trails.sort_by(&:distance), trails
  end

  test "malformed responses and provider errors are not empty successes" do
    [[], {}, { "elements" => nil }, { "elements" => [], "remark" => "runtime error: timed out" }, "not json"].each do |body|
      assert_raises(SearchErrors::UpstreamError) do
        OverpassService.get_trails(lat: 47, lon: -122, connection: stub_connection(:post, body))
      end
    end
    [nil, {}, { "type" => "relation", "id" => "bad", "tags" => {}, "members" => [] }].each do |element|
      assert_raises(SearchErrors::UpstreamError) { fetch([element]) }
    end
    assert_raises(SearchErrors::UpstreamError) do
      OverpassService.get_trails(lat: 47, lon: -122, connection: stub_connection(:post, {}, status: 429))
    end
  end

  test "invalid origin cannot be interpolated into the query" do
    assert_raises(SearchErrors::InvalidInput) do
      OverpassService.get_trails(lat: "0);node;out;", lon: 0)
    end
  end

  test "caches OSM routes for six hours but rebuilds mutable trail results" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      connection = stub_connection(:post, { "elements" => [route_element] }) { calls += 1 }
      arguments = { lat: 47, lon: -122, connection: connection, cache: cache }
      first = OverpassService.get_trails(**arguments).first
      first.duration = 600
      first.origin = "A private origin"
      first.name.replace("Mutated name")

      travel 5.hours + 59.minutes
      second = OverpassService.get_trails(**arguments).first
      assert_equal 1, calls
      assert_nil second.duration
      assert_nil second.origin
      assert_equal "Forest Loop", second.name
      refute_same first, second

      travel 2.minutes
      OverpassService.get_trails(**arguments)
      assert_equal 2, calls
    end
  end

  test "nearby origins share a query but measure distance from where they start" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    connection = stub_connection(:post, { "elements" => [route_element] }) do |request|
      queries << URI.decode_www_form(request.body).to_h.fetch("data")[/around:[^)]*/]
    end
    arguments = { connection: connection, cache: cache }
    assert_in_delta 0, OverpassService.get_trails(lat: 47, lon: -122, **arguments).first.distance, 0.001
    assert_in_delta 0.28, OverpassService.get_trails(lat: 47.004, lon: -122, **arguments).first.distance, 0.01
    OverpassService.get_trails(lat: 47.1, lon: -122, **arguments)
    OverpassService.get_trails(lat: 47, lon: -122.1, **arguments)
    assert_equal ["around:25000,47.0,-122.0", "around:25000,47.1,-122.0", "around:25000,47.0,-122.1"], queries
  end

  test "empty successful responses are cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:post, { "elements" => [] }) { calls += 1 }
    2.times do
      assert_empty OverpassService.get_trails(lat: 47, lon: -122, connection: connection, cache: cache)
    end
    assert_equal 1, calls
  end

  test "invalid responses and provider failures are never cached" do
    [
      [200, "not json"],
      [200, { "elements" => nil }],
      [200, { "elements" => [nil] }],
      [200, { "elements" => [], "remark" => "timed out" }],
      [429, { "elements" => [] }]
    ].each do |status, body|
      cache = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      connection = stub_connection(:post, body, status: status) { calls += 1 }
      2.times do
        assert_raises(SearchErrors::UpstreamError) do
          OverpassService.get_trails(lat: 47, lon: -122, connection: connection, cache: cache)
        end
      end
      assert_equal 2, calls
    end
  end

  test "timeouts are never cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:post, {}) do
      calls += 1
      raise Faraday::TimeoutError
    end
    2.times do
      assert_raises(SearchErrors::UpstreamError) do
        OverpassService.get_trails(lat: 47, lon: -122, connection: connection, cache: cache)
      end
    end
    assert_equal 2, calls
  end
end
