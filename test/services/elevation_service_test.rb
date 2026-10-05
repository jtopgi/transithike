require "test_helper"
require_relative "search_test_support"

class ElevationServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  # Tiles where the land rises 100 m for every 0.01 degrees north of 47, recording the paths asked for.
  def rising(requests = [])
    tiles_returning(requests) { |path| terrain_tile(path) { |latitude| (latitude - 47) * 10_000 } }
  end

  def tiles_returning(requests = [], status: 200, &body)
    made = {}
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(%r{\A/terrarium/}) do |env|
        requests << env.url.path
        [status, { "Content-Type" => "image/png" }, made[env.url.path] ||= body.call(env.url.path)]
      end
    end
    Faraday.new(url: "https://tiles.test/terrarium/") { |builder| builder.adapter :test, stubs }
  end

  def terrain(trails, connection:, cache: ActiveSupport::Cache::MemoryStore.new, tiles: TileCache.new(20))
    ElevationService.terrain(trails, connection: connection, cache: cache, tiles: tiles)
  end

  # A route running north from 47 for 0.03 degrees, about 3.3 km, with a point every 0.001 degrees.
  def trail(id, east: 0)
    points = (0..30).map { |step| [47 + step * 0.001, -122.0 + east] }
    OverpassService::Trail.new(osm_id: id, path: [points.first(16), points.drop(15)])
  end

  test "a route's climb runs from its lowest point to its highest, whose relief is how far it stands above the land around it" do
    requests = []
    found = terrain([trail(1)], connection: rising(requests)).fetch(1)
    # The highest point, at 47.03, stands 300 m above the start and 181 m above the land 2 km south of it,
    # to within the tiles' pixels, about 50 m apart.
    assert_in_delta 300, found[:climb], 5
    assert_in_delta 181, found[:relief], 5
    # Each tile holding the route or the land around it is fetched once, at zoom 11.
    assert_equal requests.uniq, requests
    assert requests.all? { |path| path.match?(%r{\A/terrarium/11/\d+/\d+\.png\z}) }
    assert_includes requests, "/terrarium/11/329/720.png"
  end

  test "relief is roughly how far the land rises across each route's box, from coarse tiles each asked for once" do
    requests = []
    routes = [{ id: 1, bounds: [47.0, -122.0, 47.03, -121.99] }, { id: 2, bounds: [47.01, -122.0, 47.01, -122.0] }]
    found = ElevationService.reliefs(routes, connection: rising(requests), tiles: TileCache.new(20))
    # The land rises 300 m across the first route's box, to within the coarse tiles' pixels, about 400 m apart.
    assert_in_delta 300, found.fetch(1), 40
    assert_equal 0, found.fetch(2)
    assert_equal ["/terrarium/8/41/90.png"], requests
  end

  test "routes on coarse tiles that can't be loaded are left out, and each such tile is asked for once" do
    requests = []
    routes = [{ id: 1, bounds: [47.0, -122.0, 47.03, -121.99] }, { id: 2, bounds: [47.01, -122.0, 47.02, -122.0] }]
    broken = tiles_returning(requests, status: 503) { "" }
    assert_equal({}, ElevationService.reliefs(routes, connection: broken, tiles: TileCache.new(20)))
    assert_equal 1, requests.size
  end

  test "tiles are shared by routes, and each route's terrain is cached for a month" do
    travel_to Time.utc(2026, 9, 22, 12) do
      cache, tiles, requests = ActiveSupport::Cache::MemoryStore.new, TileCache.new(20), []
      connection = rising(requests)
      trails = (1..3).map { |id| trail(id, east: id * 0.001) }
      assert_equal [1, 2, 3], terrain(trails, connection: connection, cache: cache, tiles: tiles).keys
      fetched = requests.size

      # A route nearby needs no more tiles, and the others' terrain is cached.
      assert_equal [1, 4], terrain([trails.first, trail(4, east: 0.004)], connection: connection, cache: cache, tiles: tiles).keys
      assert_equal fetched, requests.size
      terrain(trails, connection: connection, cache: cache, tiles: TileCache.new(20))
      assert_equal fetched, requests.size

      travel 30.days + 1.minute
      terrain(trails.first(1), connection: connection, cache: cache, tiles: TileCache.new(20))
      assert_operator requests.size, :>, fetched
    end
  end

  test "routes without a path need no lookup, and short ones use every point" do
    requests = []
    connection = rising(requests)
    short = OverpassService::Trail.new(osm_id: 2, path: [[[47.0, -122.0], [47.01, -122.0]]])
    found = terrain([OverpassService::Trail.new(osm_id: 1, path: []), short], connection: connection)
    assert_nil found[1]
    assert_in_delta 100, found[2][:climb], 5
    # The land 2 km south of its highest point is below sea level, which counts as sea level.
    assert_in_delta 100, found[2][:relief], 5
    assert_equal({}, terrain([], connection: connection))
    assert_equal 64, ElevationService.profile([(0..200).map { |step| [47 + step * 0.001, -122.0] }]).size
  end

  test "tiles are decoded through each of PNG's row filters, with land below sea level and gaps in the data at sea level" do
    height = ->(column, row) { (column * 7_919 + row * 104_729) % 9_000 - 500 + (column % 4) / 4.0 }
    png = terrarium_png(&height)
    expected = (0...256).flat_map { |row| (0...256).map { |column| [height.(column, row), 0].max.round } }
    assert_equal expected, ElevationService.decode(png).unpack("n*")

    # A river holding its bed's depth, and a gap in the data, beside a ridge 300 m up.
    tile = terrarium_png { |column, _row| column < 100 ? -12 : column == 100 ? -6_198 : 300 }
    assert_equal [0, 0, 300], ElevationService.decode(tile).unpack("n*").values_at(0, 100, 101)
  end

  test "a point's pixel is found in the Web Mercator tile holding it" do
    assert_equal [0, 0, 0, 0], ElevationService.pixel(85.1, -180)
    assert_equal [1024, 1024, 0, 0], ElevationService.pixel(0, 0)
    assert_equal [2047, 2047, 255, 255], ElevationService.pixel(-89, 180)
    # Midtown Manhattan.
    assert_equal [603, 769], ElevationService.pixel(40.7527, -73.9772).first(2)
  end

  test "invalid tiles and provider errors surface, and aren't cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    flat = terrarium_png { 50 }
    unfiltered = ("\x05".b + ("\x00".b * 768)) * 256
    [
      "not a png",
      flat.byteslice(0, 200),
      terrarium_png(header: [256, 256, 8, 6, 0, 0, 0].pack("NNC5")) { 50 },
      terrarium_png(header: [256, 256, 8, 2, 0, 0, 1].pack("NNC5")) { 50 },
      terrarium_png(pixels: 128) { 50 },
      flat.sub("IDAT".b, "IDAX".b),
      "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", [256, 256, 8, 2, 0, 0, 0].pack("NNC5")) + png_chunk("IDAT", Zlib::Deflate.deflate(unfiltered)),
      "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", [256, 256, 8, 2, 0, 0, 0].pack("NNC5")) + png_chunk("IDAT", Zlib::Deflate.deflate("\x00".b * 400_000)),
      "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", [256, 256, 8, 2, 0, 0, 0].pack("NNC5")) + png_chunk("IDAT", "not zlib")
    ].each do |body|
      assert_raises(SearchErrors::UpstreamError) { terrain([trail(1)], connection: tiles_returning { body }, cache: cache) }
    end
    assert_raises(SearchErrors::UpstreamError) do
      terrain([trail(1)], connection: tiles_returning(status: 404) { "Not found" }, cache: cache)
    end
    assert_nil cache.read("elevation:terrain:v2:1")
  end

  test "the tile cache keeps the most recently used tiles" do
    tiles, made = TileCache.new(2), []
    fetch = ->(key) { tiles.fetch(key) { made << key; "tile #{key}" } }
    %w[a b a c].each { |key| fetch.(key) }
    # Using a again kept it, so c pushed out b.
    assert_equal %w[a b c], made
    assert_equal "tile a", fetch.("a")
    fetch.("b")
    assert_equal %w[a b c b], made
    assert_equal 2, tiles.size
    tiles.clear
    assert_equal 0, tiles.size
  end
end
