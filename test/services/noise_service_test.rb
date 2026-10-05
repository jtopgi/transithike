require "test_helper"
require_relative "search_test_support"

class NoiseServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  # The zoom-12 tile holding Harriman State Park, whose pixels the routes here cross.
  TILE = [1204, 1536].freeze

  def tiles_returning(requests = [], status: 200, &body)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(%r{\A/noise/}) do |env|
        requests << env.url.path
        [status, { "Content-Type" => "image/png" }, body.call(env.url.path)]
      end
    end
    Faraday.new(url: "https://tiles.test/noise/") { |builder| builder.adapter :test, stubs }
  end

  # Clear in the tile's western quarter, then 45, 50, and 60 dB a quarter each.
  def banded
    tiles_returning { noise_png { |column, _row| [nil, 45, 50, 60][column / 64] } }
  end

  # The [latitude, longitude] of a pixel's middle in TILE.
  def point(column, row)
    scale = 2**NoiseService::ZOOM
    longitude = (TILE[0] + (column + 0.5) / 256) / scale * 360 - 180
    latitude = Math.atan(Math.sinh(Math::PI * (1 - 2 * (TILE[1] + (row + 0.5) / 256) / scale))) * 180 / Math::PI
    [latitude, longitude]
  end

  # A route along a row of TILE through the columns.
  def trail(id, columns, row: 128)
    OverpassService::Trail.new(osm_id: id, path: [columns.map { |column| point(column, row) }])
  end

  def noise(trails, connection:, cache: ActiveSupport::Cache::MemoryStore.new)
    NoiseService.noise(trails, connection: connection, cache: cache, tiles: TileCache.new(4))
  end

  test "a route's noise is how quiet its points are on average, and the share of them at 60 dB or more" do
    assert_equal TILE, ElevationService.pixel(*point(0, 0), NoiseService::ZOOM).first(2)
    requests = []
    connection = tiles_returning(requests) { noise_png { |column, _row| [nil, 45, 50, 60][column / 64] } }
    across = trail(1, (2..254).step(4))
    cache = ActiveSupport::Cache::MemoryStore.new
    # A quarter of its points are quiet, a quarter two thirds so, a quarter one third so, and a quarter loud.
    assert_equal({ 1 => { quiet: 0.5, loud: 0.25 } }, noise([across], connection: connection, cache: cache))
    assert_equal ["/noise/12/#{TILE[1]}/#{TILE[0]}"], requests
    # Each route's noise is kept, and routes without a path have none.
    assert_equal({ 1 => { quiet: 0.5, loud: 0.25 }, 2 => nil },
      noise([across, OverpassService::Trail.new(osm_id: 2, path: [])], connection: connection, cache: cache))
    assert_equal 1, requests.size
  end

  test "routes with more than half their points at 60 dB or more are loud" do
    assert NoiseService.loud?(noise([trail(1, (192..255))], connection: banded)[1])
    refute NoiseService.loud?(noise([trail(2, (128..255))], connection: banded)[2])
    refute NoiseService.loud?(nil)
  end

  test "tiles are decoded through each of PNG's row filters, colors off the legend count as the nearest on it" do
    level = ->(column, row) { [nil, 45, 50, 55, 60, 70, 80, 90][(column + row) % 8] }
    assert_equal (0...256).flat_map { |row| (0...256).map { |column| level.(column, row) || 0 } },
      NoiseService.decode(noise_png(&level)).bytes
    # A pinker red than the legend's 60 dB.
    assert_equal [60], NoiseService.decode(noise_png(extra: [[250, 60, 150]]) { [250, 60, 150] }).bytes.uniq
  end

  test "invalid tiles and provider errors surface, and aren't cached" do
    cache = ActiveSupport::Cache::MemoryStore.new
    clear = noise_png { nil }
    [
      "not a png",
      clear.byteslice(0, 200),
      # An RGB tile, like elevation tiles, and a palette tile without its palette.
      terrarium_png { 50 },
      clear.sub("PLTE".b, "PLTX".b)
    ].each do |body|
      assert_raises(SearchErrors::UpstreamError) { noise([trail(1, [0])], connection: tiles_returning { body }, cache: cache) }
    end
    assert_raises(SearchErrors::UpstreamError) do
      noise([trail(1, [0])], connection: tiles_returning(status: 404) { "Not found" }, cache: cache)
    end
    assert_nil cache.read("noise:v1:1")
  end

  test "the noise map covers searches in the 48 contiguous states' time zones" do
    assert NoiseService.covers?("America/New_York")
    assert NoiseService.covers?("America/Los_Angeles")
    assert NoiseService.covers?("America/Indiana/Indianapolis")
    %w[America/Anchorage Pacific/Honolulu America/Toronto Europe/London UTC Mars/Olympus].each do |zone|
      refute NoiseService.covers?(zone), zone
    end
    refute NoiseService.covers?(nil)
  end
end
