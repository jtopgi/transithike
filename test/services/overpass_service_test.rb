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

  def search_element(radius = "80000")
    { "type" => "search", "id" => 1, "tags" => { "radius" => radius } }
  end

  # Trails from the full route elements, through the area and details queries.
  def fetch(routes, lat: 47.0, access: nil, paved: [], queries: nil, cache: Rails.cache)
    connection = overpass_connection(routes: routes, paved: paved, queries: queries)
    ids = OverpassService.pick(candidates(connection, lat: lat, cache: cache)[:routes], lat: lat, lon: -122.0, access: access)
    OverpassService.trails_for(ids, lat: lat, lon: -122.0, access: access, connections: [connection], cache: cache)
  end

  def trails_for(ids, connection, cache: Rails.cache)
    OverpassService.trails_for(ids, lat: 47.0, lon: -122.0, connections: [connection], cache: cache)
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

  test "the area query widens until it finds enough routes, from a point shared nearby, and reports how far it went" do
    queries = []
    route = route_element
    route["tags"]["wikidata"] = "Q1"
    found = candidates(overpass_connection(routes: [route], queries: queries, radius: 40_000), lat: 47.6038, lon: -122.3301)

    query = queries.sole
    assert_includes query, "[timeout:20]"
    assert_includes query, 'relation(around:10000,47.6,-122.35)["type"="route"]["route"="hiking"]->.routes;' \
      "make search radius=10000->.searched;"
    assert_includes query, 'if (routes.count(relations) < 250) { relation(around:20000,47.6,-122.35)'
    assert_includes query, 'if (routes.count(relations) < 250) { relation(around:80000,47.6,-122.35)'
    assert query.end_with?(".routes out tags bb;.searched out;")
    assert_equal 40_000, found[:radius]
    assert_equal({ id: 123, name: "Forest Loop", longitude: -122.0, bounds: [47.0, -122.0, 47.02, -122.0], span: 2224,
      notable: true }, found[:routes].sole.except(:latitude))
    assert_in_delta 47.01, found[:routes].sole[:latitude], 1e-9
  end

  test "an area query must report one searched radius it asked for" do
    [[], [search_element("5000")], [search_element("x")], [search_element, search_element],
      [{ "type" => "search", "id" => 1, "tags" => "80000" }]].each do |searched|
      assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, { "elements" => searched })) }
    end
  end

  test "candidates leave out other relations and routes too small or too long for a day hike" do
    other = route_element(id: 1)
    other["tags"]["route"] = "bicycle"
    unbounded = route_element(id: 2).slice("type", "id", "tags")
    tiny = route_element(id: 3)
    tiny["members"].first["geometry"].last["lat"] = 47.002
    long = route_of(31, id: 4)
    elements = [other, unbounded, tiny, long, route_element(id: 5)].map { |route| route["members"] ? candidate_of(route) : route }
    assert_equal [5], candidates(stub_connection(:post, { "elements" => elements + [search_element] }))[:routes].pluck(:id)
  end

  test "malformed responses and provider errors are not empty successes" do
    [[], {}, { "elements" => nil }, { "elements" => [], "remark" => "runtime error: timed out" }, "not json"].each do |body|
      assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, body)) }
    end
    [nil, {}, { "type" => "relation", "id" => "bad", "tags" => {} }, { "type" => "relation", "id" => 1 }].each do |element|
      assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, { "elements" => [element, search_element] })) }
    end
    assert_raises(SearchErrors::UpstreamError) { candidates(stub_connection(:post, {}, status: 429)) }
  end

  test "a failing instance falls back to the other, which searches then prefer for a while" do
    cache = ActiveSupport::Cache::MemoryStore.new
    busy = stub_connection(:post, {}, status: 504)
    assert_equal OverpassService::URLS, OverpassService.urls(cache)

    found = OverpassService.candidates(lat: 47, lon: -122, connections: [busy, overpass_connection], cache: cache)
    assert_equal [123], found[:routes].pluck(:id)
    assert_equal OverpassService::URLS.reverse, OverpassService.urls(cache)

    assert_raises(SearchErrors::UpstreamError) do
      OverpassService.candidates(lat: 48, lon: -122, connections: [busy, busy], cache: cache)
    end
    assert_equal OverpassService::URLS, OverpassService.urls(cache)
  end

  test "queries wait for one of the process's two slots, highlights don't wait, and cached lookups need none" do
    slots = Rails.configuration.x.overpass_slots
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = overpass_connection
    counted = stub_connection(:post, { "elements" => [] }) { calls += 1 }
    cached = candidates(connection, cache: cache)
    trails = [OverpassService::Trail.new(osm_id: 1, path: [[[47.0, -122.0], [47.02, -122.0]]])]
    assert slots.try_acquire(2, 1)

    assert_equal cached, candidates(counted, cache: cache)
    error = stub_const(OverpassService, :SLOT_WAIT_SECONDS, 0.05) do
      assert_raises(SearchErrors::ProviderBusy) { candidates(counted, lat: 48.0, cache: cache) }
    end
    assert_equal OverpassService::BUSY, error.message
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(SearchErrors::ProviderBusy) { OverpassService.highlights(trails, connections: [counted], cache: cache) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.05
    assert_equal 0, calls
    assert_nil cache.read(OverpassService::FAILOVER_KEY)
  ensure
    slots.release(2)
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

  # A stop km north of the origin, reached in minutes.
  def stop(kilometers, minutes, station: false, east: 0)
    [47.0 + kilometers / 111.195, -122.0 + east, minutes, 1, station]
  end

  def far_cells(stops, beyond: 80_000)
    OverpassService.far_cells(stops, 47.0, -122.0, beyond)
  end

  test "stops beyond the searched area are grouped into cells" do
    stops = [stop(79, 60), stop(85, 70), stop(85.5, 75), stop(90, 80, station: true)]
    assert_equal [[47.75, -122.0], [47.8, -122.0]], far_cells(stops)
    assert_empty far_cells(stops, beyond: 100_000)
  end

  test "where there are too many cells, those with stations come first, spread over travel times" do
    stations = (0...30).map { |index| stop(100, 60 + index, station: true, east: index * 0.1) }
    buses = (0...30).map { |index| stop(100, 30 + index, east: -0.1 - index * 0.1) }
    cells = far_cells(stations + buses)
    assert_equal OverpassService::MAX_FAR_CELLS, cells.size
    assert_equal stations.map { |station| [47.9, (station[1] * 20).round / 20.0] }, cells.first(30)
    assert_equal [-122.1, -122.4, -122.7, -123.1], cells.drop(30).first(4).map(&:last)
    assert_equal(-125.0, cells.last.last)
    assert_equal [1, 5, 9], OverpassService.spread((1..9).to_a, 3)
    assert_equal [1], OverpassService.spread([1, 2], 1)
    assert_empty OverpassService.spread([1, 2], 0)
  end

  test "routes near stops beyond the searched area are found in one query, cached per cell" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      queries = []
      near_a = route_element(id: 1, latitude: 47.75)
      near_b = route_element(id: 2, latitude: 47.79, name: "Ridge")
      elsewhere = route_element(id: 3, latitude: 48.5, name: "Far away")
      connection = overpass_connection(routes: [], far: [near_a, near_b, elsewhere], queries: queries)
      arguments = { lat: 47.0, lon: -122.0, beyond: 80_000, connections: [connection], cache: cache }

      found = OverpassService.candidates_near([stop(85, 70), stop(90, 80, station: true)], **arguments)
      assert_equal [1, 2], found.pluck(:id).sort
      assert_equal ['relation(around:5500,47.75,-122.0)["type"="route"]["route"="hiking"];',
        'relation(around:5500,47.8,-122.0)["type"="route"]["route"="hiking"];'], queries.sole.scan(/relation\([^;]*;/)
      assert queries.sole.end_with?(");out tags bb;")

      OverpassService.candidates_near([stop(90, 80), stop(95, 90)], **arguments)
      assert_equal ['relation(around:5500,47.85,-122.0)["type"="route"]["route"="hiking"];'], queries.last.scan(/relation\([^;]*;/)
      assert_empty OverpassService.candidates_near([stop(10, 20)], **arguments)
      assert_equal 2, queries.size

      travel 1.day + 1.minute
      OverpassService.candidates_near([stop(90, 80)], **arguments)
      assert_equal 3, queries.size
    end
  end

  test "maps geometry to miles, route start, preview and the share on paved ways" do
    route = route_element
    route["members"] << { "type" => "way", "ref" => 456, "role" => "",
      "geometry" => [{ "lat" => 47.02, "lon" => -122.0 }, { "lat" => 47.025, "lon" => -122.0 }] }
    route["tags"]["website"] = "javascript:alert(1)"
    queries = []
    trail = fetch([route], paved: [456], queries: queries).sole

    assert_includes queries.last, "relation(id:123)->.routes;.routes out geom;way(r.routes)->.ways;"
    assert_includes queries.last, 'way.ways["footway"="sidewalk"];'
    assert_equal "Forest Loop", trail.name
    assert_equal "A wooded walk", trail.summary
    assert_equal [47.0, -122.0], [trail.latitude, trail.longitude]
    assert_in_delta 1.727, trail.length, 0.001
    assert_equal 0.2, trail.paved
    refute trail.notable
    refute trail.loop
    assert_equal 123, trail.osm_id
    assert_equal [[[47.0, -122.0], [47.02, -122.0]], [[47.02, -122.0], [47.025, -122.0]]], trail.path
    assert_equal [47.02, -122.0], trail.midpoint
    assert_in_delta 0, trail.distance, 0.001
    assert_nil trail.duration
  end

  test "routes mostly on paved paths or roads are walks, not day hikes" do
    route = route_element
    route["members"] << { "type" => "way", "ref" => 456, "role" => "",
      "geometry" => [{ "lat" => 47.02, "lon" => -122.0 }, { "lat" => 47.04, "lon" => -122.0 }] }
    assert_empty fetch([route], paved: [456])
    assert_equal [123], fetch([route], paved: []).map(&:osm_id)
  end

  test "routes that end where they start are loops" do
    closed = route_element(id: 1)
    closed["members"].first["geometry"] << { "lat" => 47.0, "lon" => -121.99 } << { "lat" => 47.0, "lon" => -122.0 }
    pieces = route_element(id: 2, name: "Pieces")
    pieces["members"] << { "type" => "way", "ref" => 7, "role" => "",
      "geometry" => [{ "lat" => 47.0, "lon" => -122.0 }, { "lat" => 47.01, "lon" => -121.99 }, { "lat" => 47.02, "lon" => -122.0 }] }
    branch = route_element(id: 3, name: "Branch")
    branch["members"] << { "type" => "way", "ref" => 8, "role" => "",
      "geometry" => [{ "lat" => 47.01, "lon" => -122.0 }, { "lat" => 47.01, "lon" => -121.98 }] }
    assert_equal({ 1 => true, 2 => true, 3 => false, 4 => false },
      fetch([closed, pieces, branch, route_element(id: 4, name: "Line")]).to_h { |trail| [trail.osm_id, trail.loop] })
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
    assert_in_delta 1.382, trail.length, 0.001
    assert_equal 47.02, trail.latitude
  end

  test "leaves out routes under a mile or over 30 miles" do
    assert_equal [2, 3], fetch([route_of(0.99, id: 1), route_of(1.01, id: 2), route_of(29.9, id: 3)]).map(&:osm_id)
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
    assert_empty trails_for([1, 2, 3, 4], overpass_connection(routes: routes))
    assert_raises(SearchErrors::UpstreamError) do
      trails_for([123], overpass_connection(routes: [route_element.merge("members" => "none")]))
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
      trails = trails_for([1, 2, 3], connection, cache: cache)
      assert_equal [1, 3], trails.map(&:osm_id)
      assert_includes queries.last, "relation(id:3)->"
      assert_equal "Forest Loop", trails.first.name
      assert_nil trails.first.duration

      travel 7.days + 1.minute
      trails_for([1], connection, cache: cache)
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
