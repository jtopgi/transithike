# The lay of the land along routes, from Terrain Tiles on AWS
# (https://registry.opendata.aws/terrain-tiles/): open elevation data from USGS
# 3DEP, SRTM, and other sources, served as map tiles with no key or rate limit.
# Terrain doesn't change, so each route's is kept for a month.
module ElevationService
  TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/"
  ATTRIBUTION_URL = "https://github.com/tilezen/joerd/blob/master/docs/attribution.md"
  # Zoom 11 tiles are about 15 km across, with a height about every 60 m.
  ZOOM = 11
  # Zoom 8 tiles are about 100 km across, with a height about every 400 m:
  # enough to tell hills and mountains from plains before routes are measured.
  RELIEF_ZOOM = 8
  # Heights across each route's bounding box, this many points along each side.
  RELIEF_GRID = 5
  TILE_PIXELS = 256
  # Points along each route, and around its highest point in rings this far out, in eight directions.
  PROFILE_POINTS = 64
  RING_METERS = [1_000, 2_000].freeze
  DIRECTIONS = 8
  CACHE_TTL = 30.days
  # Where each route's terrain is cached, by its id.
  TERRAIN_KEY = "elevation:terrain:v2:".freeze
  # Decoded tiles, 128 KB each, are shared by the lookups in this process.
  MAX_TILES = 200
  # Web Mercator tiles reach this far north and south.
  MAX_LATITUDE = 85.0511
  INVALID = "The elevation provider returned an invalid tile.".freeze

  # The terrain of each trail, as { osm_id => { climb:, relief: } } in meters:
  # climb is how far the highest point along it is above the lowest, and relief
  # how far that highest point stands above the lowest land within 2 km, which
  # makes for views. Each route's terrain is cached, and only uncached routes
  # are looked up.
  def self.terrain(trails, connection: nil, cache: Rails.cache, tiles: TILES)
    keys = trails.to_h { |trail| [trail.osm_id, "#{TERRAIN_KEY}#{trail.osm_id}"] }
    found = keys.empty? ? {} : cache.read_multi(*keys.values)
    RouteStore.terrain(trails.map(&:osm_id).reject { |id| found.key?(keys[id]) }).each { |id, terrain| found[keys[id]] = terrain }
    missing = trails.reject { |trail| found.key?(keys[trail.osm_id]) || profile(trail.path).empty? }
    if missing.any?
      connection ||= SearchHttp.connection(TILE_URL, timeout: 10)
      missing.each do |trail|
        points = profile(trail.path)
        heights = points.map { |point| height(*point, connection, tiles) }
        top = heights.max
        low = ring(*points[heights.index(top)]).map { |point| height(*point, connection, tiles) }.min
        found[keys[trail.osm_id]] = { climb: top - heights.min, relief: [top - low, 0].max }
        cache.write(keys[trail.osm_id], found[keys[trail.osm_id]], expires_in: CACHE_TTL)
      end
    end
    keys.transform_values { |key| found[key] }
  end

  # Roughly how far the land rises across each route's bounding box, as
  # { id => meters }, from coarse tiles, for routes as OverpassService.routes_in
  # finds them. Routes on tiles that can't be loaded are left out, and each
  # such tile is asked for only once.
  def self.reliefs(routes, connection: nil, tiles: TILES)
    connection ||= SearchHttp.connection(TILE_URL, timeout: 10)
    failed = Set.new
    routes.each_with_object({}) do |route, reliefs|
      heights = grid(route[:bounds]).map { |point| coarse_height(*point, connection, tiles, failed) }
      reliefs[route[:id]] = heights.max - heights.min unless heights.include?(nil)
    end
  end

  # RELIEF_GRID by RELIEF_GRID [latitude, longitude] points evenly across a [south, west, north, east] box.
  def self.grid(bounds)
    south, west, north, east = bounds
    steps = (0...RELIEF_GRID).map { |step| step.fdiv(RELIEF_GRID - 1) }
    steps.product(steps).map { |up, across| [south + (north - south) * up, west + (east - west) * across] }
  end

  # The height at a point from a coarse tile, or nil when its tile can't be loaded.
  def self.coarse_height(latitude, longitude, connection, tiles, failed)
    tile = pixel(latitude, longitude, RELIEF_ZOOM).first(2)
    return if failed.include?(tile)

    height(latitude, longitude, connection, tiles, RELIEF_ZOOM)
  rescue SearchErrors::UpstreamError
    failed << tile
    nil
  end

  # Up to PROFILE_POINTS [latitude, longitude] points spread along a path of lines.
  def self.profile(path)
    points = Array(path).flatten(1)
    return points if points.size <= PROFILE_POINTS

    (0...PROFILE_POINTS).map { |index| points[(index * (points.size - 1).fdiv(PROFILE_POINTS - 1)).round] }
  end

  # Points RING_METERS away from a point, in each of DIRECTIONS directions.
  def self.ring(latitude, longitude)
    east = 111_320 * [Math.cos(latitude * Math::PI / 180), 0.01].max
    RING_METERS.flat_map do |meters|
      (0...DIRECTIONS).map do |step|
        angle = step * 2 * Math::PI / DIRECTIONS
        [latitude + meters * Math.cos(angle) / 110_574, longitude + meters * Math.sin(angle) / east]
      end
    end
  end

  # The height in whole meters at a point, from the tile holding it at a zoom.
  def self.height(latitude, longitude, connection, tiles, zoom = ZOOM)
    x, y, column, row = pixel(latitude, longitude, zoom)
    heights = tiles.fetch("#{zoom}/#{x}/#{y}") { decode(SearchHttp.body { connection.get("#{zoom}/#{x}/#{y}.png") }) }
    heights.unpack1("n", offset: (row * TILE_PIXELS + column) * 2)
  end

  # The [x, y] of the Web Mercator tile holding a point at a zoom, and the point's [column, row] in it.
  def self.pixel(latitude, longitude, zoom = ZOOM)
    scale = 2**zoom
    sine = Math.sin(latitude.clamp(-MAX_LATITUDE, MAX_LATITUDE) * Math::PI / 180)
    x = ((longitude + 180) / 360.0 * scale).clamp(0, scale - 1e-9)
    y = ((0.5 - Math.log((1 + sine) / (1 - sine)) / (4 * Math::PI)) * scale).clamp(0, scale - 1e-9)
    [x.floor, y.floor, ((x % 1) * TILE_PIXELS).floor, ((y % 1) * TILE_PIXELS).floor]
  end

  # The heights in a Terrarium PNG tile, row by row, packed as 16-bit meters.
  # Tiles hold riverbeds, seabeds, and a few gaps below sea level, where the
  # surface is water at about sea level, so heights stop at 0.
  def self.decode(png)
    # 8-bit RGB, as every Terrarium tile is.
    data = PngTile.chunks(png, size: TILE_PIXELS, color: 2, invalid: INVALID)["IDAT"]
    heights = Array.new(TILE_PIXELS * TILE_PIXELS)
    PngTile.each_row(data, TILE_PIXELS, 3, INVALID) do |line, row|
      column, first = 0, row * TILE_PIXELS
      while column < TILE_PIXELS
        height = line[column * 3] * 256 + line[column * 3 + 1] + line[column * 3 + 2] / 256.0 - 32_768
        heights[first + column] = height.positive? ? height.round : 0
        column += 1
      end
    end
    heights.pack("n*")
  end

  TILES = TileCache.new(MAX_TILES)
end
