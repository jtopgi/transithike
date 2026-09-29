require "test_helper"
require_relative "search_test_support"

class OverpassServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  # Transit access keyed by bounding box, and where each path is joined.
  FakeAccess = Struct.new(:minutes, :points) do
    def reach(box) = minutes[box]
    def access_point(path) = points[path]
  end

  def candidates(connection, lat: 47.0, lon: -122.0, cache: Rails.cache)
    OverpassService.candidates(lat: lat, lon: lon, connections: [connection], cache: cache)
  end

  # Trails from the full route elements, through the area and details queries.
  def fetch(routes, lat: 47.0, access: nil, paved: [], queries: nil, cache: Rails.cache)
    connection = overpass_connection(routes: routes, paved: paved, queries: queries)
    OverpassService.trails(candidates(connection, lat: lat, cache: cache), lat: lat, lon: -122.0, access: access,
      connections: [connection], cache: cache)
  end

  # A straight route of the given length in miles, starting at the origin.
  def route_of(miles, id: 123)
    route = route_element(id: id, name: "Ridge #{id}")
    route["members"].first["geometry"].last["lat"] = 47.0 + miles * OverpassService::METERS_PER_MILE / 111_195
    route
  end

  def candidate(id, kilometers, name: "Ridge #{id}", notable: false, span: 1_000)
    latitude = 47.0 + kilometers / 111.195
    { id: id, name: name, latitude: latitude, longitude: -122.0, bounds: [latitude, -122.0, latitude, -122.0],
      span: span, notable: notable }
  end

  def pick(candidates, access: nil)
    OverpassService.pick(candidates, lat: 47.0, lon: -122.0, access: access)
  end

  test "the area query widens until it finds enough routes, from a point shared nearby" do
    queries = []
    route = route_element
    route["tags"]["wikidata"] = "Q1"
    found = candidates(overpass_connection(routes: [route], queries: queries), lat: 47.6038, lon: -122.3301)

    query = queries.sole
    assert_includes query, "[timeout:20]"
    assert_includes query, 'relation(around:10000,47.6,-122.35)["type"="route"]["route"="hiking"]->.routes;'
    assert_includes query, 'if (routes.count(relations) < 250) { relation(around:20000,47.6,-122.35)'
    assert_includes query, 'if (routes.count(relations) < 250) { relation(around:80000,47.6,-122.35)'
    assert query.end_with?(".routes out tags bb;")
    assert_equal({ id: 123, name: "Forest Loop", longitude: -122.0, bounds: [47.0, -122.0, 47.01, -122.0], span: 1112,
      notable: true }, found.sole.except(:latitude))
    assert_in_delta 47.005, found.sole[:latitude], 1e-9
  end

  test "candidates leave out other relations and routes too small or too long for a day hike" do
    other = route_element(id: 1)
    other["tags"]["route"] = "bicycle"
    unbounded = route_element(id: 2).slice("type", "id", "tags")
    tiny = route_element(id: 3)
    tiny["members"].first["geometry"].last["lat"] = 47.002
    long = route_of(31, id: 4)
    elements = [other, unbounded, tiny, long, route_element(id: 5)].map { |route| route["members"] ? candidate_of(route) : route }
    assert_equal [5], candidates(stub_connection(:post, { "elements" => elements })).pluck(:id)
  end

  test "malformed responses and provider errors are not empty successes" do
    [[], {}, { "elements" => nil }, { "elements" => [], "remark" => "runtime error: timed out" }, "not json"].each do |body|
      assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, body)) }
    end
    [nil, {}, { "type" => "relation", "id" => "bad", "tags" => {} }, { "type" => "relation", "id" => 1 }].each do |element|
      assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, { "elements" => [element] })) }
    end
    assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, {}, status: 429)) }
  end

  test "a failing instance falls back to the other, which searches then prefer for a while" do
    cache = ActiveSupport::Cache::MemoryStore.new
    busy = stub_connection(:post, {}, status: 504)
    assert_equal OverpassService::URLS, OverpassService.urls(cache)

    found = OverpassService.candidates(lat: 47, lon: -122, connections: [busy, overpass_connection], cache: cache)
    assert_equal [123], found.pluck(:id)
    assert_equal OverpassService::URLS.reverse, OverpassService.urls(cache)

    assert_raises(SearchErrors::UpstreamError) do
      OverpassService.candidates(lat: 48, lon: -122, connections: [busy, busy], cache: cache)
    end
    assert_equal OverpassService::URLS, OverpassService.urls(cache)
  end

  test "invalid origin cannot be interpolated into the query" do
    assert_raises(SearchErrors::InvalidInput) { OverpassService.candidates(lat: "0);node;out;", lon: 0) }
  end

  test "an area's routes are cached for a day and shared by origins within about 5 km" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      queries = []
      connection = overpass_connection(queries: queries)
      [[47.0, -122.0], [47.02, -122.02], [47.03, -122.0]].each do |lat, lon|
        OverpassService.candidates(lat: lat, lon: lon, connections: [connection], cache: cache)
      end
      assert_equal ["47.0,-122.0", "47.05,-122.0"], queries.map { |query| query[/around:10000,([^)]*)/, 1] }

      travel 1.day + 1.minute
      OverpassService.candidates(lat: 47.0, lon: -122.0, connections: [connection], cache: cache)
      assert_equal 3, queries.size
    end
  end

  test "failed area queries are never cached" do
    [[200, "not json"], [200, { "elements" => nil }], [200, { "elements" => [], "remark" => "timed out" }],
      [429, { "elements" => [] }]].each do |status, body|
      cache = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      connection = stub_connection(:post, body, status: status) { calls += 1 }
      2.times { assert_raises(SearchErrors::UpstreamError) { candidates(connection, cache: cache) } }
      assert_equal 2, calls
    end

    calls = 0
    connection = stub_connection(:post, {}) do
      calls += 1
      raise Faraday::TimeoutError
    end
    cache = ActiveSupport::Cache::MemoryStore.new
    2.times { assert_raises(SearchErrors::UpstreamError) { candidates(connection, cache: cache) } }
    assert_equal 2, calls
  end

  test "without transit stops, each distance ring gets its share of checks, then the nearest of the rest" do
    rings = [[1, 50, 5], [101, 60, 25], [201, 40, 50]]
    all = rings.flat_map { |first, count, km| (0...count).map { |step| candidate(first + step, km + step * 0.01) } }
    assert_equal [*1..40, *101..150, *201..230], pick(all.shuffle)

    few = all.reject { |route| route[:id].between?(11, 50) }
    assert_equal [*1..10, *101..150, *201..230, *151..160, *231..240], pick(few)
  end

  test "promising routes are checked first within a ring" do
    routes = [candidate(1, 2, name: "Trail 1"), candidate(2, 3, span: 500), candidate(3, 4, notable: true, span: 500),
      candidate(4, 5)]
    assert_equal [3, 4, 2, 1], pick(routes)
    assert OverpassService.generic_name?("Microsoft Red Fitness Loop")
    assert OverpassService.generic_name?(OverpassService::UNNAMED)
    assert OverpassService.generic_name?(nil)
    refute OverpassService.generic_name?("Loop Trail to Twin Falls")
  end

  test "sections of one trail are checked once, but namesakes farther away are kept" do
    routes = [candidate(1, 1, name: "Twin Falls Trail"), candidate(2, 3, name: "twin-falls trail"),
      candidate(3, 20, name: "Twin Falls Trail"), candidate(4, 2, name: nil), candidate(5, 4, name: nil)]
    assert_equal [1, 4, 5, 3], pick(routes)
  end

  test "with transit stops, the section of a trail that transit reaches soonest is kept" do
    near, far = candidate(1, 13, name: "Foo Trail"), candidate(2, 16, name: "Foo Trail")
    assert_equal [2], pick([near, far], access: FakeAccess.new({ far[:bounds] => 30 }))
    assert_equal [2], pick([near, far], access: FakeAccess.new({ near[:bounds] => 90, far[:bounds] => 30 }))
    assert_equal [1], pick([near, far], access: FakeAccess.new({ near[:bounds] => 30, far[:bounds] => 90 }))
  end

  test "with transit stops, only routes transit may reach are checked, most promising and quickest first" do
    routes = [candidate(1, 30), candidate(2, 1), candidate(3, 50, notable: true), candidate(4, 2)]
    access = FakeAccess.new({ routes[0][:bounds] => 60, routes[1][:bounds] => 90, routes[2][:bounds] => 120 })
    assert_equal [3, 1, 2], pick(routes, access: access)
  end

  test "maps geometry to miles, route start, preview and the share on paved ways" do
    route = route_element
    route["members"] << { "type" => "way", "ref" => 456, "role" => "",
      "geometry" => [{ "lat" => 47.01, "lon" => -122.0 }, { "lat" => 47.03, "lon" => -122.0 }] }
    route["tags"]["website"] = "javascript:alert(1)"
    queries = []
    trail = fetch([route], paved: [456], queries: queries).sole

    assert_includes queries.last, "relation(id:123)->.routes;.routes out geom;way(r.routes)->.ways;"
    assert_includes queries.last, 'way.ways["footway"="sidewalk"];'
    assert_equal "Forest Loop", trail.name
    assert_equal "A wooded walk", trail.summary
    assert_equal [47.0, -122.0], [trail.latitude, trail.longitude]
    assert_in_delta 2.073, trail.length, 0.001
    assert_equal 0.67, trail.paved
    refute trail.notable
    assert_equal 123, trail.osm_id
    assert_equal [[[47.0, -122.0], [47.01, -122.0]], [[47.01, -122.0], [47.03, -122.0]]], trail.path
    assert_equal [47.01, -122.0], trail.midpoint
    assert_in_delta 0, trail.distance, 0.001
    assert_nil trail.duration
  end

  test "reports distance from the origin in miles" do
    trail = fetch([route_element], lat: 47.01).sole
    assert_in_delta 0.691, trail.distance, 0.001
  end

  test "route previews are downsampled but keep every way's ends" do
    route = route_element
    route["members"].first["geometry"] = (0..400).map { |step| { "lat" => 47.0 + step * 0.0001, "lon" => -122.0 } }
    path = fetch([route]).sole.path
    assert_equal 1, path.size
    assert_operator path.first.size, :<=, OverpassService::PREVIEW_POINTS + 1
    assert_equal [47.0, -122.0], path.first.first
    assert_equal [47.04, -122.0], path.first.last
  end

  test "deduplicates member ways and honors backward orientation" do
    route = route_element
    route["members"].first["role"] = "backward"
    route["members"] << route["members"].first.dup
    trail = fetch([route]).sole
    assert_in_delta 0.691, trail.length, 0.001
    assert_equal 47.01, trail.latitude
  end

  test "leaves out routes under half a mile or over 30 miles" do
    assert_equal [2, 3], fetch([route_of(0.49, id: 1), route_of(0.51, id: 2), route_of(29.9, id: 3)]).map(&:osm_id)
    assert_equal [], fetch([])
  end

  test "skips incomplete geometry, nested relations and routes without measurable length" do
    missing = route_element(id: 1)
    missing["members"].first.delete("geometry")
    partial = route_element(id: 2)
    partial["members"].first["geometry"] << nil
    nested = route_element(id: 3)
    nested["members"] << { "type" => "relation", "ref" => 99 }
    zero = route_element(id: 4)
    zero["members"].first["geometry"].last["lat"] = 47.0
    routes = [missing, partial, nested, zero]
    connection = overpass_connection(routes: routes)
    candidates = (1..4).map { |id| candidate(id, 0) }
    assert_empty OverpassService.trails(candidates, lat: 47.0, lon: -122.0, connections: [connection], cache: Rails.cache)
    assert_raises(SearchErrors::UpstreamError) do
      invalid = route_element.merge("members" => "none")
      OverpassService.trails([candidate(123, 0)], lat: 47.0, lon: -122.0,
        connections: [overpass_connection(routes: [invalid])], cache: Rails.cache)
    end
  end

  test "uses honest unnamed route fallback" do
    route = route_element
    route["tags"].delete("name")
    route["tags"].delete("description")
    trail = fetch([route]).sole
    assert_equal OverpassService::UNNAMED, trail.name
    assert_includes trail.summary, "OpenStreetMap"
  end

  test "with transit stops, directions lead to where transit reaches each route soonest" do
    routes = [route_element(id: 1), route_element(id: 2, latitude: 47.1)]
    paths = routes.to_h { |route| [OverpassService.route_attributes(route, Set.new)[:path], nil] }
    paths[paths.keys.first] = [47.005, -122.0]
    trail = fetch(routes, access: FakeAccess.new(Hash.new(30), paths)).sole
    assert_equal 1, trail.osm_id
    assert_equal [47.005, -122.0], [trail.latitude, trail.longitude]
    assert_in_delta 0.345, trail.distance, 0.001
  end

  test "route details are cached for a week, and only uncached routes are queried" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      nested = route_element(id: 2, name: "Nested Loop")
      nested["members"] << { "type" => "relation", "ref" => 99 }
      queries = []
      first = fetch([route_element(id: 1), nested], queries: queries, cache: cache).sole
      first.duration = 600
      first.name.replace("Mutated name")

      connection = overpass_connection(routes: [route_element(id: 1), nested, route_element(id: 3, latitude: 47.02)],
        queries: queries)
      trails = OverpassService.trails([1, 2, 3].map { |id| candidate(id, id / 10.0) }, lat: 47.0, lon: -122.0,
        connections: [connection], cache: cache)
      assert_equal [1, 3], trails.map(&:osm_id)
      assert_includes queries.last, "relation(id:3)->"
      assert_equal "Forest Loop", trails.first.name
      assert_nil trails.first.duration

      travel 7.days + 1.minute
      OverpassService.trails([candidate(1, 0)], lat: 47.0, lon: -122.0, connections: [connection], cache: cache)
      assert_includes queries.last, "relation(id:1)->"
    end
  end

  test "highlights near each route, waterfalls first and named before unnamed" do
    near = route_element(id: 1)
    far = route_element(id: 2, latitude: 47.5)
    trails = fetch([near, far])
    nodes = [highlight_node("viewpoint", 47.005, -122.001, name: "Lookout"), highlight_node("viewpoint", 47.008, -122.0),
      highlight_node("waterfall", 47.002, -121.999), highlight_node("peak", 47.01, -122.0, name: "Knob"),
      highlight_node("peak", 47.3, -122.0, name: "Elsewhere"), { "type" => "node", "id" => 9, "lat" => 47.0, "lon" => -122.0 }]
    queries = []
    connection = overpass_connection(highlights: nodes, queries: queries)
    highlights = OverpassService.highlights(trails, connections: [connection], cache: Rails.cache)

    assert_includes queries.sole, "relation(id:1,2);way(r)->.ways;"
    assert_includes queries.sole, 'node(around.ways:150)["waterway"="waterfall"];'
    assert_equal({ 1 => [{ kind: "waterfall", name: nil }, { kind: "peak", name: "Knob" },
      { kind: "viewpoint", name: "Lookout" }, { kind: "viewpoint", name: nil }], 2 => [] }, highlights)
  end

  test "highlights are cached per route, and failures are not" do
    cache = ActiveSupport::Cache::MemoryStore.new
    trails = fetch([route_element(id: 1)])
    calls = 0
    failing = stub_connection(:post, {}, status: 504) { calls += 1 }
    assert_raises(SearchErrors::UpstreamError) { OverpassService.highlights(trails, connections: [failing], cache: cache) }

    working = overpass_connection(highlights: [highlight_node("peak", 47.01, -122.0, name: "Knob")])
    assert_equal({ 1 => [{ kind: "peak", name: "Knob" }] }, OverpassService.highlights(trails, connections: [working], cache: cache))
    assert_equal({ 1 => [{ kind: "peak", name: "Knob" }] }, OverpassService.highlights(trails, connections: [failing], cache: cache))
    assert_equal 1, calls
    assert_equal({}, OverpassService.highlights([], connections: [failing], cache: cache))
  end
end
