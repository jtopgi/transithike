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

  def routes_in(connection, tiles: [TILE], cache: Rails.cache, failures: nil)
    OverpassService.routes_in(tiles, connections: [connection], cache: cache, failures: failures)
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
  def pick(candidates, access: FakeAccess.new(Hash.new(60)), relief: {})
    OverpassService.pick(candidates, access: access, relief: relief)
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
    assert_empty OverpassService.tiles([])
  end

  # A station in the middle of the tile in this row and column from 47, -122, reached in minutes.
  def centered(row, column, minutes)
    [47.25 + row * OverpassService::TILE_DEGREES, -121.75 + column * OverpassService::TILE_DEGREES, minutes]
  end

  test "each band of travel time has its share of the tiles, so the scenery farther out is searched too" do
    # Fifteen tiles within two hours, fifteen within three, and fifteen farther.
    stations = [60, 130, 190].each_with_index.flat_map do |minutes, band|
      (0...15).map { |index| centered(band, index, minutes + index) }
    end
    tiles = OverpassService.tiles(stations)
    assert_equal 20, OverpassService::MAX_TILES
    assert_equal [[8, 47.0], [7, 47.5], [5, 48.0]], tiles.group_by(&:first).map { |row, band| [band.size, row] }
    assert_equal [47.0, -122.0], tiles.first
    assert_equal [48.0, -120.0], tiles.last

    # A band without enough tiles leaves room for more of the quickest: thirty within two hours, and two far out.
    near = (0...30).map { |index| centered(index / 15, index % 15, 60 + index) }
    few = OverpassService.tiles(near + [centered(2, 0, 190), centered(2, 1, 191)])
    assert_equal [[15, 47.0], [3, 47.5], [2, 48.0]], few.group_by(&:first).map { |row, band| [band.size, row] }
  end

  test "in each band of travel time with more tiles than its share, those where the land rises most are searched first" do
    stations = [60, 130, 190].each_with_index.flat_map do |minutes, band|
      (0...15).map { |index| centered(band, index, minutes + index) }
    end
    asked = []
    # The slowest five within two hours are in the hills.
    relief = lambda do |corners|
      asked << corners
      corners.to_h { |south, west| [[south, west], south == 47.0 && west >= -117.0 ? 600 : 90] }
    end
    near = OverpassService.tiles(stations, relief: relief).select { |south, _| south == 47.0 }.map(&:last)
    assert_equal [-122.0, -121.5, -121.0, -117.0, -116.5, -116.0, -115.5, -115.0], near.sort
    assert_equal 45, asked.sole.size

    # Bands with no more than their share don't need it.
    assert_equal [[47.0, -122.0]], OverpassService.tiles([centered(0, 0, 60)], relief: ->(_) { flunk "looked up" })
  end

  test "relief counts in whole steps up to its most, so land rising less than a step is as flat as land not looked up" do
    stations = [60, 130, 190].each_with_index.flat_map do |minutes, band|
      (0...15).map { |index| centered(band, index, minutes + index) }
    end
    relief = lambda do |corners|
      corners.to_h do |south, west|
        index = ((west + 122.0) / OverpassService::TILE_DEGREES).round
        # Within two hours, the slowest eight rise 1,000 m and the rest 350 m; within three, the slowest seven 50 m.
        [[south, west], { 47.0 => index < 7 ? 350 : 1_000, 47.5 => (50 if index >= 8) }[south]]
      end.compact
    end
    tiles = OverpassService.tiles(stations, relief: relief)
    columns = ->(row) { tiles.select { |south, _| south == row }.map { |_, west| ((west + 122.0) / OverpassService::TILE_DEGREES).round }.sort }
    assert_equal (7..14).to_a, columns.(47.0)
    assert_equal (0..6).to_a, columns.(47.5)
  end

  test "routes in tiles are found by querying the region around them, and each tile's routes are kept and refreshed" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache = ActiveSupport::Cache::MemoryStore.new
      queries = []
      inside = route_element(id: 1, latitude: 47.2)
      across = route_element(id: 2, latitude: 47.49, name: "Ridge")
      elsewhere = route_element(id: 3, latitude: 48.1, name: "Far away")
      connection = overpass_connection(routes: [inside, across, elsewhere], queries: queries)
      found = routes_in(connection, tiles: [[47.0, -122.0], [47.5, -122.0], [48.5, -122.5]], cache: cache)

      assert_equal [1, 2], found.pluck(:id).sort
      boxes = ["(47.0,-122.0,47.5,-121.5)", "(47.5,-122.0,48.0,-121.5)", "(48.5,-122.5,49.0,-122.0)"]
      wider = ["(46.95,-122.05,47.55,-121.45)", "(47.45,-122.05,48.05,-121.45)", "(48.45,-122.55,49.05,-121.95)"]
      # Named paths come too, a little beyond the tiles, but not the ways of hiking routes.
      assert_equal %([out:json][timeout:60];relation["type"="route"]["route"="hiking"](47.0,-122.5,49.0,-121.5)->.region;) +
        "(#{boxes.map { |box| "relation.region#{box};" }.join});out tags bb;" +
        %(relation["type"="route"]["route"="hiking"](46.95,-122.55,49.05,-121.45);way(r)->.routed;) +
        "way#{OverpassService::PATH_FILTER}(46.95,-122.55,49.05,-121.45)->.paths;" \
        "((#{wider.map { |box| "way.paths#{box};" }.join}); - .routed;);out body bb;", queries.sole
      # The route across two tiles is in both.
      assert_equal [2], routes_in(connection, tiles: [[47.5, -122.0]], cache: cache).pluck(:id)
      assert_equal [1, 2], routes_in(connection, tiles: [[47.5, -122.0], [47.0, -122.0]], cache: cache).pluck(:id).sort
      assert_equal 1, queries.size
      assert_empty OverpassService.routes_in([], connections: [connection], cache: cache)

      routes_in(connection, tiles: [[47.5, -122.0], [50.0, -122.0]], cache: cache)
      assert_includes queries.last, "(50.0,-122.0,50.5,-121.5)->.region;"
      # A month on, the kept routes are used at once while the tile is looked up again in the background.
      travel 30.days + 1.minute
      assert_equal [2], routes_in(connection, tiles: [[47.5, -122.0]], cache: cache).pluck(:id)
      Timeout.timeout(5) { sleep 0.01 until cache.read("#{OverpassService::TILE_KEY}47.5:-122.0")[:at] > 1.minute.ago }
      assert_equal 3, queries.size
      assert_includes queries.last, "(47.5,-122.0,48.0,-121.5)->.region;"
      routes_in(connection, tiles: [[47.5, -122.0]], cache: cache)
      assert_equal 3, queries.size
    end
  end

  test "neighboring tiles are queried a few at a time, and the routes of tiles whose query fails are left out" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    tiles = [[48.0, -121.0], [47.0, -122.0], [47.0, -121.5], [47.5, -122.0], [47.5, -121.5], [48.0, -122.0],
      [46.0, -122.0], [46.5, -122.0]]
    connection = stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      raise Faraday::ConnectionFailed, "busy" if query.include?("(48.0,-122.0,48.5,-121.5)")

      { "elements" => [candidate_of(route_element(id: 1, latitude: 47.1)), candidate_of(route_element(id: 2, latitude: 48.1))] }
    })
    failures = []
    assert_equal [1], routes_in(connection, tiles: tiles, cache: cache, failures: failures).pluck(:id)
    # The failure is told, so the search can say some hikes went unchecked.
    assert_equal [SearchErrors::UpstreamError], failures.map(&:class)
    # The first four tiles from south to west, and then the other four, asked twice when that query fails quickly.
    assert_equal ["(46.0,-122.0,47.5,-121.0)->.region;", "(47.5,-122.0,48.5,-120.5)->.region;",
      "(47.5,-122.0,48.5,-120.5)->.region;"], queries.map { |query| query[/\([^()]*\)->\.region;/] }
    # Tiles whose query worked are cached; the others are asked again.
    routes_in(connection, tiles: tiles, cache: cache)
    assert_equal 5, queries.size
    # Tiles another search finds while this one queries others aren't queried again.
    later = [[49.0, -122.0], [49.5, -122.0], [50.0, -122.0], [50.5, -122.0], [51.0, -122.0]]
    racing = stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      cache.write("#{OverpassService::TILE_KEY}51.0:-122.0", { routes: [{ id: 7 }], at: Time.current }) if query.include?("relation.region(49.0,")
      { "elements" => [] }
    })
    assert_equal [7], routes_in(racing, tiles: later, cache: cache).pluck(:id)
    assert_equal 6, queries.size
    assert_raises(SearchErrors::UpstreamError) { routes_in(connection, tiles: [[48.0, -122.0]], cache: cache) }
  end

  # Answers tiles queries with one route in every tile, holding each query
  # whose region starts at a latitude in holds until its event is set, and
  # telling when it starts.
  def held_connection(queries, holds: {}, started: Hash.new { |events, key| events[key] = Concurrent::Event.new })
    stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      south = query[/\(([-\d.]+),[-\d.]+,[-\d.]+,[-\d.]+\)->\.region;/, 1].to_f
      started[south].set
      holds[south]&.wait(5)
      tiles = query.scan(/relation\.region\(([-\d.]+),([-\d.]+),/).map { |row, column| [row.to_f, column.to_f] }
      { "elements" => tiles.map { |row, column| candidate_of(route_element(id: (row * 10).to_i, latitude: row + 0.2)) } }
    })
  end

  test "searches that need the same tiles at once query them once, and wait only for the query that has theirs" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = Concurrent::Array.new
    first, second = Concurrent::Event.new, Concurrent::Event.new
    started = Hash.new { |events, key| events[key] = Concurrent::Event.new }
    connection = held_connection(queries, holds: { 46.0 => first, 48.0 => second }, started: started)
    tiles = (0...8).map { |index| [46.0 + index * 0.5, -122.0] }
    one = Thread.new { routes_in(connection, tiles: tiles, cache: cache) }
    assert started[46.0].wait(5)

    # Another search needs a tile in the first query, which it waits for, and one of its own, which it queries.
    other = Thread.new { routes_in(connection, tiles: [[47.0, -122.0], [52.0, -122.0]], cache: cache) }
    assert started[52.0].wait(5)
    first.set
    assert started[48.0].wait(5)
    # Its tiles are found while the first search's second query is still going.
    assert_equal [470, 520], other.join(5).value.pluck(:id).sort
    assert one.alive?
    second.set
    assert_equal (0...8).map { |index| 460 + index * 5 }, one.join(5).value.pluck(:id).sort
    assert_equal 1, queries.count { |query| query.include?("relation.region(47.0,-122.0,") }
    assert_empty OverpassService::LOOKING_UP.keys
  ensure
    [first, second].each { |event| event&.set }
    [one, other].each { |thread| thread&.join(5) }
  end

  test "a search that waits too long for another's tiles reads what it stored, and otherwise says the provider is busy" do
    reads = Concurrent::Event.new
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.define_singleton_method(:read_multi) { |*names, **options| super(*names, **options).tap { reads.set } }
    queries = Concurrent::Array.new
    hold = Concurrent::Event.new
    started = Hash.new { |events, key| events[key] = Concurrent::Event.new }
    connection = held_connection(queries, holds: { 47.0 => hold }, started: started)
    one = Thread.new { routes_in(connection, tiles: [[47.0, -122.0]], cache: cache) }
    assert started[47.0].wait(5)

    stub_const(OverpassService, :SHARED_WAIT_SECONDS, 0.2) do
      failures = []
      error = assert_raises(SearchErrors::ProviderBusy) do
        routes_in(connection, tiles: [[47.0, -122.0]], cache: cache, failures: failures)
      end
      assert_equal [OverpassService::BUSY, [SearchErrors::ProviderBusy]], [error.message, failures.map(&:class)]

      # The other search stores the tile's routes while this one waits, before it says so.
      reads.reset
      waiting = Thread.new { routes_in(connection, tiles: [[47.0, -122.0]], cache: cache) }
      assert reads.wait(5)
      cache.write("#{OverpassService::TILE_KEY}47.0:-122.0", { routes: [{ id: 9 }], at: Time.current })
      assert_equal [9], waiting.join(5).value.pluck(:id)
    end
    # Only the first search asked Overpass.
    assert_equal 1, queries.size
  ensure
    hold&.set
    one&.join(5)
  end

  test "searches that need the same routes' details at once ask for them once" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = Concurrent::Array.new
    hold, started = Concurrent::Event.new, Concurrent::Event.new
    connection = stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      started.set
      hold.wait(5)
      { "elements" => query.include?("out geom") ? [route_element(id: 1), route_element(id: 2)] : [] }
    })
    one = Thread.new { trails_for([1], connection, cache: cache) }
    assert started.wait(5)
    other = Thread.new { trails_for([1, 2], connection, cache: cache) }
    sleep 0.05 until queries.size == 2 || !other.alive?
    hold.set
    assert_equal [1], one.join(5).value.map(&:osm_id)
    assert_equal [1, 2], other.join(5).value.map(&:osm_id)
    assert_equal ["relation(id:1)", "relation(id:2)"], queries.map { |query| query[/relation\(id:[\d,]+\)/] }
  ensure
    hold&.set
    [one, other].each { |thread| thread&.join(5) }
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

    queries = []
    huge = stub_connection(:post, {}) do |request|
      queries << URI.decode_www_form(request.body).to_h.fetch("data")
      raise SearchErrors::ResponseTooLarge
    end
    assert_raises(SearchErrors::ResponseTooLarge) { routes_in(huge, cache: ActiveSupport::Cache::MemoryStore.new) }
    # The other instance would list as much, so only the tile's routes alone are asked for again.
    assert_equal [true, false], queries.map { |query| query.include?("out body bb") }
  end

  test "where named paths are too many to list with the routes, the tiles keep their routes alone" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    dense = stub_connection(:post, lambda { |request|
      queries << URI.decode_www_form(request.body).to_h.fetch("data")
      raise SearchErrors::ResponseTooLarge if queries.last.include?("out body bb")

      { "elements" => [candidate_of(route_element(id: 1))] }
    })
    assert_equal [1], routes_in(dense, cache: cache).pluck(:id)
    assert_equal [1], routes_in(dense, cache: cache).pluck(:id)
    assert_equal 2, queries.size
    assert_nil cache.read(OverpassService::FAILOVER_KEY)
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

  test "a lookup another search waits on is at least as urgent as that search, even while it looks up its own" do
    other = [Concurrent::Promises.resolvable_future, ProviderSlots::Shared.new(ProviderSlots::BACKGROUND)]
    OverpassService::LOOKING_UP.put_if_absent("tile:shared", other)
    while_own = Queue.new
    waiting = Thread.new do
      ProviderSlots.with_priority(ProviderSlots::SEARCH) do
        OverpassService.shared(["tile:shared", "tile:own"], ActiveSupport::Cache::MemoryStore.new) do |own|
          while_own << other.last.provider_priority
          own.to_h { |key| [key, [2]] }
        end
      end
    end
    assert_equal ProviderSlots::SEARCH, while_own.pop
    other.first.fulfill("tile:shared" => [1])
    assert_equal({ "tile:own" => [2], "tile:shared" => [1] }, waiting.value)
  ensure
    OverpassService::LOOKING_UP.delete("tile:shared")
  end

  test "queries wait for one of the process's two slots, highlights a visitor waits on don't, and cached lookups need none" do
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
    assert_raises(SearchErrors::ProviderBusy) do
      ProviderSlots.with_priority(ProviderSlots::VISITOR) { OverpassService.highlights(trails, connections: [counted], cache: cache) }
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.05
    # Highlights no visitor waits on, as in guide builds, wait for a slot like other queries.
    stub_const(OverpassService, :SLOT_WAIT_SECONDS, 0.05) do
      assert_raises(SearchErrors::ProviderBusy) { OverpassService.highlights(trails, connections: [counted], cache: cache) }
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.05
    assert_equal 0, calls
    assert_nil cache.read(OverpassService::FAILOVER_KEY)
  ensure
    slots.release(2)
  end

  test "only routes transit may reach are checked, most promising and quickest first" do
    routes = [candidate(1, 30), candidate(2, 1), candidate(3, 50, notable: true), candidate(4, 2)]
    access = FakeAccess.new({ routes[0][:bounds] => 60, routes[1][:bounds] => 90, routes[2][:bounds] => 120 })
    assert_equal [3, 1, 2], pick(routes, access: access)
    many = (1..170).map { |id| candidate(id, id) }
    assert_equal (1..OverpassService::MAX_TRANSIT_ROUTES).to_a, pick(many, access: FakeAccess.new(Hash.new { |_, box| box[0] }))
  end

  test "some routes three hours or more away are checked, however promising nearer ones are" do
    near = (1..130).map { |id| candidate(id, 1, notable: true) }
    far = (131..300).map { |id| candidate(id, 3) }
    access = FakeAccess.new(Hash.new { |_, box| box[0] > 47.02 ? OverpassService::FAR_MINUTES : 60 })
    picked = pick(near + far, access: access)
    assert_equal [80, 40], picked.partition { |id| id <= 130 }.map(&:size)
    assert_equal picked.select { |id| id <= 130 }, picked.first(80)

    # Without enough near routes, more far ones are checked.
    assert_equal [30, 90], pick(near.first(30) + far, access: access).partition { |id| id <= 130 }.map(&:size)

    # Routes already checked count toward both, and aren't picked again.
    checked = (near.first(30) + far.first(10)).pluck(:id).to_set
    more = OverpassService.pick(near + far, access: access, checked: checked)
    assert_equal [50, 30], more.partition { |id| id <= 130 }.map(&:size)
    assert_empty more.select { |id| checked.include?(id) }
    assert_empty OverpassService.pick(near + far, access: access, checked: (1..120).to_set)
  end

  test "named paths that aren't hiking routes are routes too, each the ways of one name joined at a node" do
    paths = [path_way(1, nodes: [10, 11]), path_way(2, nodes: [11, 12], latitude: 47.02),
      # The same name elsewhere is another trail, and a short path isn't one.
      path_way(3, nodes: [30, 31], latitude: 47.3), path_way(4, name: "Lot Path", nodes: [40, 41], latitude: 47.4, length: 0.001)]
    found = routes_in(overpass_connection(routes: [route_element(id: 9)], paths: paths), cache: ActiveSupport::Cache::MemoryStore.new)
    assert_equal [[9, nil], [-1, [1, 2]], [-3, [3]]], found.map { |route| route.values_at(:id, :ways) }
    joined = found.find { |route| route[:id] == -1 }
    assert_equal ["Mount Si Trail", [47.0, -122.0, 47.04, -122.0], 4448, false],
      [joined[:name], joined[:bounds].map { |degrees| degrees.round(6) }, joined[:span], joined[:notable]]
  end

  test "a named path is measured from its ways and kept with them, and its highlights are found along them" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    paths = [path_way(1, nodes: [10, 11], length: 0.03), path_way(2, nodes: [11, 12], latitude: 47.03, surface: "asphalt")]
    peak = highlight_node("peak", 47.05, -122.0, name: "Mount Si")
    connection = overpass_connection(routes: [], paths: paths, paved: [2], highlights: [peak], queries: queries)
    trail = OverpassService.trails_for([-1], lat: 47.0, lon: -122.0, connections: [connection], cache: cache,
      paths: { -1 => [1, 2] }).sole
    assert_includes queries.last, "way(id:1,2)->.named;.named out tags geom;(.named;)->.measured;"
    assert_equal ["Mount Si Trail", false, 0.4, "https://www.openstreetmap.org/way/1"], [trail.name, trail.loop, trail.paved, trail.osm_url]
    assert_in_delta 3.45, trail.length, 0.01
    # It starts at a loose end.
    assert_includes [47.0, 47.05], trail.latitude
    assert_equal [1, 2], cache.read("#{OverpassService::ROUTE_KEY}-1")[:ways]

    assert_equal({ -1 => [{ kind: "peak", name: "Mount Si" }] }, OverpassService.highlights([trail], connections: [connection], cache: cache))
    assert_includes queries.last, "way(id:1,2)->.named;(.named;)->.ways;"

    # A named path whose ways aren't known isn't looked up, or written off as unmeasurable.
    assert_empty OverpassService.trails_for([-5], lat: 47.0, lon: -122.0, connections: [connection], cache: cache)
    assert_equal 2, queries.size
    assert_not cache.exist?("#{OverpassService::ROUTE_KEY}-5")
  end

  test "a trail across a tile's edge is one, whichever tiles list its pieces, and measured from all its ways" do
    cache = ActiveSupport::Cache::MemoryStore.new
    queries = []
    # Way 100 crosses 47.5° north, between way 200 to its south and way 300 to its north.
    across = path_way(100, nodes: [1, 2], latitude: 47.48, length: 0.04)
    south, north = path_way(200, nodes: [3, 1], latitude: 47.4, length: 0.08), path_way(300, nodes: [2, 4], latitude: 47.52, length: 0.08)
    connection = stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries << query
      named = query[/way\(id:([\d,]+)\)->\.named/, 1].to_s.split(",").map(&:to_i)
      ways = if query.include?("out ids") then [across, south, north].select { |way| named.include?(way["id"]) }
      elsif query.include?("relation.region(47.0,") then [across, south].map { |way| listed_way(way) }
      else [across, north].map { |way| listed_way(way) }
      end
      { "elements" => ways }
    })
    found = stub_const(OverpassService, :TILES_PER_QUERY, 1) do
      routes_in(connection, tiles: [[47.0, -122.0], [47.5, -122.0]], cache: cache)
    end
    assert_equal 2, queries.size
    assert_equal [[-100, [100, 200, 300]]], found.map { |route| route.values_at(:id, :ways) }

    # Measured from the pieces one tile listed, it's measured again once its other ways are known.
    first = OverpassService.trails_for([-100], lat: 47.4, lon: -122.0, connections: [connection], cache: cache,
      paths: { -100 => [100, 200] }).sole
    whole = OverpassService.trails_for([-100], lat: 47.4, lon: -122.0, connections: [connection], cache: cache,
      paths: { -100 => [100, 300] }).sole
    assert_includes queries.last, "way(id:100,200,300)->.named;"
    assert_equal [100, 200, 300], cache.read("#{OverpassService::ROUTE_KEY}-100")[:ways]
    assert_in_delta first.length * 5 / 3, whole.length, 0.01
  end

  test "a named path that can't be measured again keeps what was measured, a while, and ways gone since aren't asked for again" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    down = stub_connection(:post, {}) do
      calls += 1
      raise Faraday::ConnectionFailed, "timed out"
    end
    cache.write("#{OverpassService::ROUTE_KEY}-1", { osm_id: -1, name: "Mount Si Trail", latitude: 47.0, longitude: -122.0,
      length: 2.0, path: [[[47.0, -122.0], [47.03, -122.0]]], loop: false, paved: 0.0, ways: [1, 2] })
    failures = []
    measure = -> { OverpassService.trails_for([-1], lat: 47.0, lon: -122.0, connections: [down], cache: cache, failures: failures, paths: { -1 => [1, 2, 3] }) }
    assert_equal ["Mount Si Trail"], measure.().map(&:name)
    assert_empty failures
    asked = calls
    assert_equal ["Mount Si Trail"], measure.().map(&:name)
    assert_equal asked, calls

    # Measured from ways 1 and 2, though 3 has gone, it isn't measured again for 3.
    queries = []
    paths = [path_way(1, nodes: [10, 11]), path_way(2, nodes: [11, 12], latitude: 47.02)]
    gone = overpass_connection(routes: [], paths: paths, queries: queries)
    2.times do
      OverpassService.trails_for([-7], lat: 47.0, lon: -122.0, connections: [gone], cache: cache, paths: { -7 => [1, 2, 3] })
    end
    assert_equal 1, queries.size
    assert_equal [1, 2, 3], cache.read("#{OverpassService::ROUTE_KEY}-7")[:ways]
  end

  test "a named path is a little less promising than a hiking route alike" do
    assert_equal [1, -1], pick([candidate(-1, 10, name: "Cougar Ridge"), candidate(1, 10, name: "Squak Ridge")])
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

  test "routes across hilly land are checked first, and long trips there count against routes" do
    notable, hilly, mountains, flat = candidate(1, 10, notable: true), candidate(2, 20), candidate(3, 30), candidate(4, 40)
    access = FakeAccess.new({ notable[:bounds] => 60, hilly[:bounds] => 60, mountains[:bounds] => 180, flat[:bounds] => 30 })
    # Land rising 300 m outweighs a Wikipedia article, and mountains three hours away
    # still do, though the trip there counts against them; relief counts up to 400 m.
    assert_equal [2, 3, 1, 4], pick([notable, hilly, mountains, flat], access: access,
      relief: { 2 => 300, 3 => 2_000, 4 => 20 })
    assert_equal [1, 4, 2, 3], pick([notable, hilly, mountains, flat], access: access)
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
    assert_includes queries.last, 'way.measured["footway"="sidewalk"];'
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

  test "route details are kept for two months, and only routes without them are queried" do
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

      travel 60.days + 1.minute
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

    assert_includes queries.sole, "relation(id:1,2);way(r)->.routed;(.routed;)->.ways;"
    assert_includes queries.sole, 'node(around.ways:150)["waterway"="waterfall"];'
    assert_equal({ 1 => [{ kind: "waterfall" }, { kind: "peak", name: "Knob" },
      { kind: "viewpoint", name: "Lookout" }, { kind: "viewpoint" }], 2 => [] }, highlights)
  end

  test "highlights with a Wikipedia article are famous and come first, and waterfalls have their height in meters" do
    trails = fetch([route_element(id: 1)])
    famous = highlight_node("peak", 47.012, -122.0, name: "Big Knob")
    famous["tags"].merge!("wikipedia" => "en:Big Knob", "wikidata" => "Q1")
    # Every named hill has a Wikidata item, so that alone isn't enough.
    hill = highlight_node("peak", 47.01, -122.0, name: "Little Knob")
    hill["tags"]["wikidata"] = "Q34807513"
    falls = [["25 m", 25.0], ["80 ft", 24.4], ["6", 6.0], ["tall", nil], ["0", nil]].each_with_index.map do |(height, _), index|
      highlight_node("waterfall", 47.002 + index * 0.001, -121.999, name: "Falls #{index}").tap { |node| node["tags"]["height"] = height }
    end
    connection = overpass_connection(highlights: [hill, famous, *falls])
    found = OverpassService.highlights(trails, connections: [connection], cache: ActiveSupport::Cache::MemoryStore.new)[1]

    assert_equal [{ kind: "peak", name: "Big Knob", notable: true }, { kind: "peak", name: "Little Knob" }],
      found.select { |highlight| highlight[:kind] == "peak" }
    assert_equal [25.0, 24.4, 6.0, nil, nil], found.select { |highlight| highlight[:kind] == "waterfall" }.map { |highlight| highlight[:height] }
  end

  test "highlights are cached per route, and failures are not" do
    ProviderSlots.with_priority(ProviderSlots::VISITOR) { highlights_cached_per_route }
  end

  # As a visitor's lookup, which isn't tried again.
  def highlights_cached_per_route
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
