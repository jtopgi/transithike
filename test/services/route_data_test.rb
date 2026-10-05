require "test_helper"
require_relative "search_test_support"

class RouteDataTest < ActiveSupport::TestCase
  include SearchTestSupport

  PATH = [[[47.3, -122.0], [47.32, -122.0]]].freeze

  teardown do
    RouteStore.enabled = true
    RouteStore.reachable!
  end

  # A connection that fails any request, so lookups must use what's stored.
  def unreachable
    stubs = Faraday::Adapter::Test::Stubs.new
    Faraday.new(url: "https://provider.test") { |builder| builder.adapter :test, stubs }
  end

  # A connection whose queries fail, as Overpass's do from the Azure server.
  def failing
    stub_connection(:post, ->(_) { raise Faraday::ConnectionFailed, "timed out" })
  end

  # What a build records, as a guide build's cache does, exported and read back.
  def collected
    recorder = RouteData::Recorder.new
    recorder.write("#{OverpassService::TILE_KEY}47.0:-122.5",
      { routes: [{ id: 7, name: "Ridge Loop", latitude: 47.31, longitude: -122.0, bounds: [47.3, -122.0, 47.32, -122.0],
        span: 2224, notable: false }], at: Time.utc(2026, 10, 7, 9) })
    recorder.write("#{OverpassService::ROUTE_KEY}7", { osm_id: 7, name: "Ridge Loop", summary: "A wooded walk.", latitude: 47.3,
      longitude: -122.0, length: 1.38, path: PATH, loop: false, paved: 0.0, notable: false })
    recorder.write("#{OverpassService::ROUTE_KEY}8", false)
    recorder.write("#{OverpassService::HIGHLIGHTS_KEY}7", [{ kind: "waterfall", name: "Twin Falls" }])
    recorder.write("#{ElevationService::TERRAIN_KEY}7", { climb: 220, relief: 198 })
    recorder.write("#{NoiseService::KEY}7", { quiet: 1.0, typical: 0, loudest: 45 })
    recorder.write("transitous:departures:v2:abc", [1])
    recorder
  end

  def import(recorder, at: Time.utc(2026, 10, 7, 10))
    file = Tempfile.new(%w[routes .ndjson.gz])
    RouteData.export(recorder.recorded, file.path)
    Zlib::GzipReader.open(file.path) { |gz| RouteData.import(gz, at: at) }
  ensure
    file&.close!
  end

  test "a build records what it looks up of each hiking route and tile, and nothing else" do
    recorded = collected.recorded
    assert_equal 6, recorded.size
    assert_nil recorded["transitous:departures:v2:abc"]
    assert_equal false, recorded["#{OverpassService::ROUTE_KEY}8"]
    assert_equal ["tile", "47.0:-122.5"], RouteData.kind("#{OverpassService::TILE_KEY}47.0:-122.5")
    assert_nil RouteData.kind("transitous:departures:v2:abc")
  end

  test "searches read the routes builds collected, without asking the providers" do
    assert_equal 6, import(collected)
    cache = ActiveSupport::Cache::MemoryStore.new
    routes = OverpassService.routes_in([[47.0, -122.5]], connections: [unreachable], cache: cache)
    assert_equal [[7, "Ridge Loop", [47.3, -122.0, 47.32, -122.0]]], routes.map { |route| route.values_at(:id, :name, :bounds) }

    trail = OverpassService.trails_for([7, 8], lat: 47.0, lon: -122.0, connections: [unreachable], cache: cache).sole
    assert_equal ["Ridge Loop", PATH, 1.38], [trail.name, trail.path, trail.length]
    assert_equal({ 7 => [{ kind: "waterfall", name: "Twin Falls" }] },
      OverpassService.highlights([trail], connections: [unreachable], cache: cache))
    assert_equal({ 7 => { climb: 220, relief: 198 } }, ElevationService.terrain([trail], connection: unreachable, cache: cache))
    assert_equal({ 7 => { quiet: 1.0, typical: 0, loudest: 45 } }, NoiseService.noise([trail], connection: unreachable, cache: cache))
  end

  test "what's stored is kept when the other routes looked up with it can't be" do
    import(collected)
    cache = ActiveSupport::Cache::MemoryStore.new
    failures = []
    trails = OverpassService.trails_for([9, 7], lat: 47.0, lon: -122.0, connections: [failing], cache: cache, failures: failures)
    assert_equal ["Ridge Loop"], trails.map(&:name)
    assert_equal [SearchErrors::UpstreamError], failures.map(&:class)
    assert_raises(SearchErrors::UpstreamError) do
      OverpassService.trails_for([9], lat: 47.0, lon: -122.0, connections: [failing], cache: cache)
    end

    unstored = OverpassService::Trail.new(osm_id: 9, path: PATH)
    assert_equal({ 7 => [{ kind: "waterfall", name: "Twin Falls" }] },
      OverpassService.highlights([unstored, trails.sole], connections: [failing], cache: cache))
    assert_raises(SearchErrors::UpstreamError) { OverpassService.highlights([unstored], connections: [failing], cache: cache) }
  end

  test "a database that can't be reached is left alone for a while, so lookups don't each wait for it" do
    import(collected)
    calls = 0
    HikingRoute.define_singleton_method(:where) do |*|
      calls += 1
      raise ActiveRecord::ConnectionNotEstablished, "timeout expired"
    end
    stub_const(FailOpenCache, :PAUSE_SECONDS, 0.2) do
      assert_empty RouteStore.details([7])
      assert_empty RouteStore.tiles([[47.0, -122.5]])
      assert_equal 1, calls
      HikingRoute.singleton_class.remove_method(:where)
      sleep 0.25
      assert_equal "Ridge Loop", RouteStore.details([7])[7][:name]
    end
  ensure
    HikingRoute.singleton_class.remove_method(:where) if HikingRoute.singleton_class.method_defined?(:where, false)
  end

  test "a newer file replaces what was stored of each route, and keeps the rest" do
    import(collected)
    newer = RouteData::Recorder.new
    newer.write("#{ElevationService::TERRAIN_KEY}7", { climb: 230, relief: 200 })
    import(newer, at: Time.utc(2026, 10, 14, 10))
    route = HikingRoute.find(7)
    assert_equal [{ "climb" => 230, "relief" => 200 }, "Ridge Loop", Time.utc(2026, 10, 14, 10)],
      [route.terrain, route.details["name"], route.collected_at]
    assert_equal({ 8 => false }, RouteStore.details([8]))
  end

  test "builds don't read the database, as they collect what it holds" do
    import(collected)
    RouteStore.enabled = false
    assert_empty RouteStore.details([7])
    assert_empty RouteStore.tiles([[47.0, -122.5]])
  end

  test "the server imports the newest published file once, following its download's redirect" do
    file = Tempfile.new(%w[routes .ndjson.gz])
    RouteData.export(collected.recorded, file.path)
    gzipped = File.binread(file.path)
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(RouteData::RELEASE_URL) do |env|
        requests << env.url.to_s
        assets = [{ name: "routes-20261007100000.ndjson.gz", browser_download_url: "https://github.test/routes-20261007100000.ndjson.gz" },
          { name: "routes-20260930100000.ndjson.gz", browser_download_url: "https://github.test/old.ndjson.gz" },
          { name: "notes.txt", browser_download_url: "https://github.test/notes.txt" }]
        [200, {}, JSON.generate(assets: assets)]
      end
      stub.get("https://github.test/routes-20261007100000.ndjson.gz") do |env|
        requests << env.url.to_s
        [302, { "Location" => "https://objects.github.test/routes" }, ""]
      end
      stub.get("https://objects.github.test/routes") do |env|
        requests << env.url.to_s
        [200, {}, gzipped]
      end
    end
    connection = Faraday.new { |builder| builder.adapter :test, stubs }
    cache = ActiveSupport::Cache::MemoryStore.new
    log = Logger.new(StringIO.new)

    assert_equal "routes-20261007100000.ndjson.gz", RouteData.import_newest(connection: connection, cache: cache, log: log)
    assert_equal "Ridge Loop", RouteStore.details([7])[7][:name]
    assert_equal 3, requests.size
    assert_nil RouteData.import_newest(connection: connection, cache: cache, log: log)
    assert_equal 4, requests.size
  ensure
    file&.close!
  end

  test "before any file is published, nothing is imported" do
    stubs = Faraday::Adapter::Test::Stubs.new { |stub| stub.get(RouteData::RELEASE_URL) { [404, {}, "{}"] } }
    connection = Faraday.new { |builder| builder.adapter :test, stubs }
    assert_nil RouteData.import_newest(connection: connection, cache: ActiveSupport::Cache::MemoryStore.new)
  end
end
