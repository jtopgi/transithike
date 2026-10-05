# How loud traffic is along routes in the 48 contiguous US states, from the
# U.S. DOT Bureau of Transportation Statistics' National Transportation Noise
# Map (https://www.bts.gov/geospatial/national-transportation-noise-map): road,
# rail, and aviation noise, modeled for 2022 as the average sound level over a
# day, served as map tiles with no key. Routes away from traffic rank higher,
# and routes mostly beside loud traffic aren't shown. The map doesn't change,
# so each route's noise is kept for 90 days.
module NoiseService
  TILE_URL = "https://tiles.arcgis.com/tiles/xOi1kZaI0eWDREZv/arcgis/rest/services/" \
    "NTAD_Noise_2022_CONUS_aviation_rail_road/MapServer/tile/".freeze
  ATTRIBUTION_URL = "https://www.bts.gov/geospatial/national-transportation-noise-map".freeze
  # Zoom 12 tiles, the finest the map has, are about 7 km across, with a level about every 30 m.
  ZOOM = 12
  TILE_PIXELS = 256
  # The map's colors, and the sound levels in decibels they start at. It leaves places under 45 dB clear.
  LEVELS = { [255, 193, 7] => 45, [255, 128, 0] => 50, [255, 0, 0] => 55, [255, 51, 153] => 60,
    [163, 0, 204] => 70, [82, 0, 204] => 80, [0, 0, 255] => 90 }.freeze
  # How quiet a place is, from 1 under 45 dB to 0 from 55 dB, about as loud as a busy street nearby.
  QUIETNESS = { 0 => 1.0, 45 => 2 / 3.0, 50 => 1 / 3.0 }.freeze
  # Routes with more than LOUD_SHARE of their points at LOUD_DB or louder are
  # mostly beside busy roads, highways, or railways, or under flight paths.
  LOUD_DB = 60
  LOUD_SHARE = 0.5
  # A route's loudest level is the one at least this share of its points
  # reach, so that crossing a road doesn't count.
  LOUDEST_SHARE = 0.05r
  # The contiguous states lie within these latitudes and longitudes.
  LATITUDES = (24.0..50.0)
  LONGITUDES = (-125.0..-66.0)
  CACHE_TTL = 90.days
  # Decoded tiles, 64 KB each, are shared by the lookups in this process.
  MAX_TILES = 200
  INVALID = "The noise map returned an invalid tile.".freeze

  # Whether the map covers searches in the time zone: the 48 contiguous states'.
  def self.covers?(time_zone)
    @zones ||= TZInfo::Country.get("US").zone_info
      .select { |zone| zone.latitude < 50 && zone.longitude > -125 }.to_set(&:identifier)
    time_zone.present? && @zones.include?(TZInfo::Timezone.get(time_zone).canonical_identifier)
  rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::InvalidCountryCode, TZInfo::DataSourceNotFound
    false
  end

  # Whether the map covers a place: within the contiguous states' bounds and
  # in one of their time zones, from transit's area. Raises when the area
  # can't be looked up.
  def self.covers_place?(latitude, longitude, transit: TransitousService)
    LATITUDES.cover?(latitude) && LONGITUDES.cover?(longitude) && covers?(transit.area(latitude, longitude)[:time_zone])
  end

  # The noise along each trail, as { osm_id => { quiet:, loud:, typical:, loudest: } }:
  # quiet is how quiet its points are on average, from 0 to 1, loud the share
  # of them at LOUD_DB or louder, typical the level along at least half of it,
  # in decibels from LEVELS or 0 under 45 dB, and loudest the level at least
  # LOUDEST_SHARE of it reaches. Each route's noise is cached, and only
  # uncached routes are looked up. Raises when a tile can't be loaded.
  def self.noise(trails, connection: nil, cache: Rails.cache, tiles: TILES)
    keys = trails.to_h { |trail| [trail.osm_id, "noise:v2:#{trail.osm_id}"] }
    found = keys.empty? ? {} : cache.read_multi(*keys.values)
    missing = trails.reject { |trail| found.key?(keys[trail.osm_id]) || ElevationService.profile(trail.path).empty? }
    if missing.any?
      connection ||= SearchHttp.connection(TILE_URL, timeout: 10)
      missing.each do |trail|
        levels = ElevationService.profile(trail.path).map { |point| level(*point, connection, tiles) }
        found[keys[trail.osm_id]] = summary(levels)
        cache.write(keys[trail.osm_id], found[keys[trail.osm_id]], expires_in: CACHE_TTL)
      end
    end
    keys.transform_values { |key| found[key] }
  end

  # A route's noise, as #noise gives it, from the levels at its points.
  def self.summary(levels)
    sorted = levels.sort
    { quiet: (levels.sum { |level| QUIETNESS.fetch(level, 0.0) } / levels.size).round(2),
      loud: levels.count { |level| level >= LOUD_DB }.fdiv(levels.size).round(2),
      typical: sorted[levels.size / 2], loudest: sorted[-(levels.size * LOUDEST_SHARE).ceil] }
  end

  # Whether a route's noise, as #noise gives it, says it's mostly beside loud traffic.
  def self.loud?(noise)
    noise.present? && noise[:loud] > LOUD_SHARE
  end

  # The sound level at a point, in decibels from LEVELS, or 0 under 45 dB.
  def self.level(latitude, longitude, connection, tiles)
    x, y, column, row = ElevationService.pixel(latitude, longitude, ZOOM)
    levels = tiles.fetch("#{x}/#{y}") { decode(SearchHttp.body { connection.get("#{ZOOM}/#{y}/#{x}") }) }
    levels.getbyte(row * TILE_PIXELS + column)
  end

  # The sound levels in a tile, a byte for each pixel row by row, from the
  # palette colors the map draws them in. Clear colors are under 45 dB, and
  # colors not on the map's legend count as the nearest one on it.
  def self.decode(png)
    chunks = PngTile.chunks(png, size: TILE_PIXELS, color: 3, invalid: INVALID)
    raise SearchErrors::UpstreamError, INVALID unless chunks["PLTE"] && (chunks["PLTE"].bytesize % 3).zero?

    alpha = chunks["tRNS"].to_s.bytes
    by_index = chunks["PLTE"].bytes.each_slice(3).each_with_index.map do |color, index|
      alpha.fetch(index, 255).zero? ? 0 : LEVELS.min_by { |legend, _| legend.zip(color).sum { |a, b| (a - b)**2 } }.last
    end
    levels = String.new(capacity: TILE_PIXELS**2, encoding: Encoding::BINARY)
    PngTile.each_row(chunks["IDAT"], TILE_PIXELS, 1, INVALID) do |line, _row|
      levels << line.map { |index| by_index.fetch(index, 0) }.pack("C*")
    end
    levels
  end

  TILES = TileCache.new(MAX_TILES)
end
