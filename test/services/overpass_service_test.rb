require "test_helper"
require_relative "search_test_support"

class OverpassServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  # Transit access keyed by bounding box, and where each path is joined.
  FakeAccess = Struct.new(:minutes, :points) do
    def reach(box) = minutes[box]
    def access_point(path) = points[path]
  end

  TILE = [47.0, -122.0].freeze

  def routes_in(connection, tiles: [TILE], cache: Rails.cache)
    OverpassService.routes_in(tiles, connections: [connection], cache: cache)
  end

  # Trails from the full route elements, through the tiles and details queries.
  def fetch(routes, lat: 47.0, access: nil, paved: [], queries: nil, cache: Rails.cache)
    connection = overpass_connection(routes: routes, paved: paved, queries: queries)
    candidates = routes_in(connection, cache: cache)
    ids = access ? OverpassService.pick(candidates, access: access) : candidates.pluck(:id)
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

  # Transit reaches every route in 60 minutes unless told otherwise.
  def pick(candidates, access: FakeAccess.new(Hash.new(60)))
    OverpassService.pick(candidates, access: access)
  end

  # A station km north and east of 47, -122, reached in minutes.
  def station(north, east, minutes)
    [47.0 + north / 111.195, -122.0 + east / (111.32 * Math.cos(47 * Math::PI / 180)), minutes]
  end

  test "tiles hold the routes within a walk of the stations, those with the quickest stations first" do
    # Two inside one tile, one within a walk of four tiles' corner, and one in another tile.
    stations = [station(20, 20, 90), station(1, 1, 60), station(60, 60, 120), station(21, 21, 45)]
    assert_equal [[47.0, -122.0], [46.5, -122.5], [46.5, -122.0], [47.0, -122.5], [47.5, -121.5]],
      OverpassService.tiles(stations)
    many = (0...20).map { |index| station(100, 40 * index, 60 + index) }
    tiles = OverpassService.tiles(many)
    assert_equal OverpassService::MAX_TILES, tiles.size
    assert_equal [[47.5, -122.5], [47.5, -122.0]], tiles.first(2)
    assert_empty OverpassService.tiles([])
  end

  test "routes in tiles are found by querying the region around them, and each tile's routes are shared for days" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      queries = []
      inside = route_element(id: 1, latitude: 47.2)
      across = route_element(id: 2, latitude: 47.49, name: "Ridge")
      elsewhere = route_element(id: 3, latitude: 48.1, name: "Far away")
      connection = overpass_connection(routes: [inside, across, elsewhere], queries: queries)
      found = routes_in(connection, tiles: [[47.0, -122.0], [47.5, -122.0], [48.5, -122.5]], cache: cache)

      assert_equal [1, 2], found.pluck(:id).sort
      assert_equal '[out:json][timeout:40];relation["type"="route"]["route"="hiking"](47.0,-122.5,49.0,-121.5)->.region;' \
        "(relation.region(47.0,-122.0,47.5,-121.5);relation.region(47.5,-122.0,48.0,-121.5);" \
        "relation.region(48.5,-122.5,49.0,-122.0););out tags bb;", queries.sole
      # The route across two tiles is in both.
      assert_equal [2], routes_in(connection, tiles: [[47.5, -122.0]], cache: cache).pluck(:id)
      assert_equal [1, 2], routes_in(connection, tiles: [[47.5, -122.0], [47.0, -122.0]], cache: cache).pluck(:id).sort
      assert_equal 1, queries.size
      assert_empty OverpassService.routes_in([], connections: [connection], cache: cache)

      routes_in(connection, tiles: [[47.5, -122.0], [50.0, -122.0]], cache: cache)
      assert_includes queries.last, "(50.0,-122.0,50.5,-121.5)->.region;"
      travel 3.days + 1.minute
      routes_in(connection, tiles: [[47.5, -122.0]], cache: cache)
      assert_equal 3, queries.size
    end
  end

  test "neighboring tiles are queried a few at a time, and the routes of tiles whose query fails are left out" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    tiles = [[48.0, -121.0], [47.0, -122.0], [47.0, -121.5], [47.5, -122.0], [47.5, -121.5], [48.0, -122.0]]
    connection = stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      raise Faraday::ConnectionFailed, "busy" if query.include?("(48.0,-122.0,48.5,-121.5)")

      { "elements" => [candidate_of(route_element(id: 1, latitude: 47.1)), candidate_of(route_element(id: 2, latitude: 48.1))] }
    })
    assert_equal [1], routes_in(connection, tiles: tiles, cache: cache).pluck(:id)
    # The first four tiles from south to west, and then the other two, asked twice when that query fails quickly.
    assert_equal ["(47.0,-122.0,48.0,-121.0)->.region;", "(48.0,-122.0,48.5,-120.5)->.region;",
      "(48.0,-122.0,48.5,-120.5)->.region;"], queries.map { |query| query[/\([^()]*\)->\.region;/] }
    # Tiles whose query worked are cached; the others are asked again.
    routes_in(connection, tiles: tiles, cache: cache)
    assert_equal 5, queries.size
    assert_raises(SearchErrors::UpstreamError) { routes_in(connection, tiles: [[48.0, -122.0]], cache: cache) }
  end

  test "failed tile queries are asked once more when they fail quickly, and are never cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    [[200, "not json"], [200, { "elements" => nil }], [200, { "elements" => [], "remark" => "timed out" }],
      [429, { "elements" => [] }], [504, "<html>Gateway Timeout</html>"]].each do |status, body|
      calls = 0
      connection = stub_connection(:post, body, status: status) { calls += 1 }
      2.times { assert_raises(SearchErrors::UpstreamError) { routes_in(connection, cache: cache) } }
      assert_equal 4, calls
    end

    calls = 0
    connection = stub_connection(:post, {}) do
      calls += 1
      raise Faraday::TimeoutError
    end
    2.times { assert_raises(SearchErrors::UpstreamError) { routes_in(connection, cache: cache) } }
    assert_equal 4, calls
  end

  test "a query that fails slowly, or is too large, is not asked again" do
    calls = 0
    slow = stub_connection(:post, {}, status: 504) { calls += 1 }
    stub_const(OverpassService, :QUICK_FAILURE_SECONDS, -1) do
      assert_raises(SearchErrors::UpstreamError) { routes_in(slow, cache: ActiveSupport::Cache::MemoryStore.new) }
    end
    assert_equal 1, calls

    calls = 0
    huge = stub_connection(:post, {}) do
      calls += 1
      raise SearchErrors::ResponseTooLarge
    end
    assert_raises(SearchErrors::ResponseTooLarge) { routes_in(huge, cache: ActiveSupport::Cache::MemoryStore.new) }
    assert_equal 1, calls
  end

  test "a query that fails quickly on both instances succeeds on the preferred one's second try" do
    cache = ActiveSupport::Cache::MemoryStore.new
    attempts = 0
    flaky = stub_connection(:post, lambda { |_|
      attempts += 1
      raise Faraday::ConnectionFailed, "busy" if attempts == 1

      { "elements" => [candidate_of(route_element)] }
    })
    busy = stub_connection(:post, {}, status: 504)
    assert_equal [123], OverpassService.routes_in([TILE], connections: [flaky, busy], cache: cache).pluck(:id)
    assert_equal 2, attempts
  end

  test "routes in tiles leave out other relations and routes too small or too long for a day hike" do
    other = route_element(id: 1)
    other["tags"]["route"] = "bicycle"
    unbounded = route_element(id: 2).slice("type", "id", "tags")
    tiny = route_element(id: 3)
    tiny["members"].first["geometry"].last["lat"] = 47.002
    long = route_of(31, id: 4)
    notable = route_element(id: 5)
    notable["tags"]["wikidata"] = "Q1"
    elements = [other, unbounded, tiny, long, notable].map { |route| route["members"] ? candidate_of(route) : route }
    found = routes_in(stub_connection(:post, { "elements" => elements })).sole
    assert_equal({ id: 5, name: "Forest Loop", longitude: -122.0, bounds: [47.0, -122.0, 47.02, -122.0], span: 2224,
      notable: true }, found.except(:latitude))
    assert_in_delta 47.01, found[:latitude], 1e-9
  end

  test "malformed responses and provider errors are not empty successes" do
    [[], {}, { "elements" => nil }, { "elements" => [], "remark" => "runtime error: timed out" }, "not json"].each do |body|
      assert_raises(SearchErrors::UpstreamError) { routes_in(stub_connection(:post, body)) }
    end
    [nil, {}, { "type" => "relation", "id" => "bad", "tags" => {} }, { "type" => "relation", "id" => 1 }].each do |element|
      assert_raises(SearchErrors::UpstreamError) { routes_in(stub_connection(:post, { "elements" => [element] })) }
    end
    assert_raises(SearchErrors::UpstreamError) { routes_in(stub_connection(:post, {}, status: 429)) }
  end

  test "a failing instance falls back to the other, which searches then prefer for a while" do
    cache = ActiveSupport::Cache::MemoryStore.new
    busy = stub_connection(:post, {}, status: 504)
    assert_equal OverpassService::URLS, OverpassService.urls(cache)

    found = OverpassService.routes_in([TILE], connections: [busy, overpass_connection], cache: cache)
    assert_equal [123], found.pluck(:id)
    assert_equal OverpassService::URLS.reverse, OverpassService.urls(cache)

    assert_raises(SearchErrors::UpstreamError) do
      OverpassService.routes_in([[48.0, -122.0]], connections: [busy, busy], cache: cache)
    end
    assert_equal OverpassService::URLS, OverpassService.urls(cache)
  end

  test "queries wait for one of the process's two slots, highlights don't wait, and cached lookups need none" do
    slots = Rails.configuration.x.overpass_slots
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = overpass_connection
    counted = stub_connection(:post, { "elements" => [] }) { calls += 1 }
    cached = routes_in(connection, cache: cache)
    trails = [OverpassService::Trail.new(osm_id: 1, path: [[[47.0, -122.0], [47.02, -122.0]]])]
    assert slots.try_acquire(2, 1)

    assert_equal cached, routes_in(counted, cache: cache)
    error = stub_const(OverpassService, :SLOT_WAIT_SECONDS, 0.05) do
      assert_raises(SearchErrors::ProviderBusy) { routes_in(counted, tiles: [[48.0, -122.0]], cache: cache) }
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

  test "only routes transit may reach are checked, most promising and quickest first" do
    routes = [candidate(1, 30), candidate(2, 1), candidate(3, 50, notable: true), candidate(4, 2)]
    access = FakeAccess.new({ routes[0][:bounds] => 60, routes[1][:bounds] => 90, routes[2][:bounds] => 120 })
    assert_equal [3, 1, 2], pick(routes, access: access)
    many = (1..130).map { |id| candidate(id, id) }
    assert_equal (1..OverpassService::MAX_TRANSIT_ROUTES).to_a, pick(many, access: FakeAccess.new(Hash.new { |_, box| box[0] }))
  end

  test "promising routes are checked first" do
    routes = [candidate(1, 2, name: "Trail 1"), candidate(2, 3, span: 500), candidate(3, 4, notable: true, span: 500),
      candidate(4, 5)]
    assert_equal [3, 4, 2, 1], pick(routes)
    assert OverpassService.generic_name?("Microsoft Red Fitness Loop")
    assert OverpassService.generic_name?(OverpassService::UNNAMED)
    assert OverpassService.generic_name?(nil)
    refute OverpassService.generic_name?("Loop Trail to Twin Falls")
  end

  test "sections of one trail are checked once, where transit reaches soonest, but namesakes farther away are kept" do
    near, far = candidate(1, 13, name: "Foo Trail"), candidate(2, 16, name: "foo-trail")
    assert_equal [2], pick([near, far], access: FakeAccess.new({ far[:bounds] => 30 }))
    assert_equal [2], pick([near, far], access: FakeAccess.new({ near[:bounds] => 90, far[:bounds] => 30 }))
    assert_equal [1], pick([near, far], access: FakeAccess.new({ near[:bounds] => 30, far[:bounds] => 90 }))
    namesake = candidate(3, 20, name: "Foo Trail")
    assert_equal [1, 3], pick([near, far, namesake], access: FakeAccess.new({ near[:bounds] => 30, far[:bounds] => 90,
      namesake[:bounds] => 60 }))
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
    far = route_element(id: 2, latitude: 47.4)
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
