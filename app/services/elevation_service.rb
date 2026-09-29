require "zlib"

# The lay of the land along routes, from Terrain Tiles on AWS
# (https://registry.opendata.aws/terrain-tiles/): open elevation data from USGS
# 3DEP, SRTM, and other sources, served as map tiles with no key or rate limit.
# Terrain doesn't change, so each route's is kept for a month.
module ElevationService
  TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/"
  ATTRIBUTION_URL = "https://github.com/tilezen/joerd/blob/master/docs/attribution.md"
  # Zoom 11 tiles are about 15 km across, with a height about every 60 m.
  ZOOM = 11
  TILE_PIXELS = 256
  # Points along each route, and around its highest point in rings this far out, in eight directions.
  PROFILE_POINTS = 64
  RING_METERS = [1_000, 2_000].freeze
  DIRECTIONS = 8
  CACHE_TTL = 30.days
  # Decoded tiles, 128 KB each, are shared by the lookups in this process.
  MAX_TILES = 200
  # Web Mercator tiles reach this far north and south.
  MAX_LATITUDE = 85.0511
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  INVALID = "The elevation provider returned an invalid tile.".freeze

  # The terrain of each trail, as { osm_id => { climb:, relief: } } in meters:
  # climb is how far the highest point along it is above the lowest, and relief
  # how far that highest point stands above the lowest land within 2 km, which
  # makes for views. Each route's terrain is cached, and only uncached routes
  # are looked up.
  def self.terrain(trails, connection: nil, cache: Rails.cache, tiles: TILES)
    keys = trails.to_h { |trail| [trail.osm_id, "elevation:terrain:v2:#{trail.osm_id}"] }
    found = keys.empty? ? {} : cache.read_multi(*keys.values)
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

  # The height in whole meters at a point, from the tile holding it.
  def self.height(latitude, longitude, connection, tiles)
    x, y, column, row = pixel(latitude, longitude)
    heights = tiles.fetch("#{ZOOM}/#{x}/#{y}") { decode(SearchHttp.body { connection.get("#{ZOOM}/#{x}/#{y}.png") }) }
    heights.unpack1("n", offset: (row * TILE_PIXELS + column) * 2)
  end

  # The [x, y] of the Web Mercator tile holding a point, and the point's [column, row] in it.
  def self.pixel(latitude, longitude)
    scale = 2**ZOOM
    sine = Math.sin(latitude.clamp(-MAX_LATITUDE, MAX_LATITUDE) * Math::PI / 180)
    x = ((longitude + 180) / 360.0 * scale).clamp(0, scale - 1e-9)
    y = ((0.5 - Math.log((1 + sine) / (1 - sine)) / (4 * Math::PI)) * scale).clamp(0, scale - 1e-9)
    [x.floor, y.floor, ((x % 1) * TILE_PIXELS).floor, ((y % 1) * TILE_PIXELS).floor]
  end

  # The heights in a Terrarium PNG tile, row by row, packed as 16-bit meters.
  # Tiles hold riverbeds, seabeds, and a few gaps below sea level, where the
  # surface is water at about sea level, so heights stop at 0.
  def self.decode(png)
    raise SearchErrors::UpstreamError, INVALID unless png.byteslice(0, 8) == PNG_SIGNATURE

    header, data, offset = nil, String.new(encoding: Encoding::BINARY), 8
    while offset + 8 <= png.bytesize
      length, type = png.unpack("Na4", offset: offset)
      break if type == "IEND"

      chunk = png.byteslice(offset + 8, length)
      raise SearchErrors::UpstreamError, INVALID unless chunk&.bytesize == length

      header = chunk.unpack("NNC5") if type == "IHDR"
      data << chunk if type == "IDAT"
      offset += length + 12
    end
    # 8-bit RGB without interlacing, as every Terrarium tile is.
    raise SearchErrors::UpstreamError, INVALID unless header == [TILE_PIXELS, TILE_PIXELS, 8, 2, 0, 0, 0]

    heights(inflate(data, TILE_PIXELS * (TILE_PIXELS * 3 + 1))).pack("n*")
  end

  # Zlib data inflated to exactly size bytes.
  def self.inflate(data, size)
    inflated = String.new(encoding: Encoding::BINARY)
    zlib = Zlib::Inflate.new
    zlib.inflate(data) do |chunk|
      inflated << chunk
      raise SearchErrors::UpstreamError, INVALID if inflated.bytesize > size
    end
    raise SearchErrors::UpstreamError, INVALID unless zlib.finished? && inflated.bytesize == size

    inflated
  rescue Zlib::Error
    raise SearchErrors::UpstreamError, INVALID
  ensure
    zlib&.close
  end

  # Each pixel's height from its red, green, and blue bytes, after undoing
  # PNG's filtering of each row by the bytes before and above.
  def self.heights(rows)
    stride = TILE_PIXELS * 3
    above = Array.new(stride, 0)
    heights = Array.new(TILE_PIXELS * TILE_PIXELS)
    TILE_PIXELS.times do |row|
      start = row * (stride + 1)
      line = rows.byteslice(start + 1, stride).bytes
      unfilter(rows.getbyte(start), line, above)
      column, first = 0, row * TILE_PIXELS
      while column < TILE_PIXELS
        height = line[column * 3] * 256 + line[column * 3 + 1] + line[column * 3 + 2] / 256.0 - 32_768
        heights[first + column] = height.positive? ? height.round : 0
        column += 1
      end
      above = line
    end
    heights
  end

  def self.unfilter(filter, line, above)
    stride = line.size
    index = 0
    case filter
    when 0
    when 1
      index = 3
      while index < stride
        line[index] = (line[index] + line[index - 3]) & 255
        index += 1
      end
    when 2
      while index < stride
        line[index] = (line[index] + above[index]) & 255
        index += 1
      end
    when 3
      while index < stride
        left = index >= 3 ? line[index - 3] : 0
        line[index] = (line[index] + (left + above[index]) / 2) & 255
        index += 1
      end
    when 4
      while index < stride
        left, up = index >= 3 ? line[index - 3] : 0, above[index]
        corner = index >= 3 ? above[index - 3] : 0
        guess = left + up - corner
        a, b, c = (guess - left).abs, (guess - up).abs, (guess - corner).abs
        line[index] = (line[index] + (a <= b && a <= c ? left : b <= c ? up : corner)) & 255
        index += 1
      end
    else
      raise SearchErrors::UpstreamError, INVALID
    end
  end

  # Tiles by key, dropping the least recently used beyond a limit.
  class TileCache
    def initialize(limit)
      @limit, @tiles, @lock = limit, {}, Mutex.new
    end

    # The tile, or the block's, which is kept. Lookups of the same missing tile at once may each run the block.
    def fetch(key)
      found = @lock.synchronize { @tiles.key?(key) ? @tiles[key] = @tiles.delete(key) : nil }
      return found if found

      tile = yield
      @lock.synchronize do
        @tiles[key] = tile
        @tiles.delete(@tiles.each_key.first) while @tiles.size > @limit
      end
      tile
    end

    def size
      @lock.synchronize { @tiles.size }
    end

    def clear
      @lock.synchronize { @tiles.clear }
    end
  end

  TILES = TileCache.new(MAX_TILES)
end
