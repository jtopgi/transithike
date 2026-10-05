# The hiking routes the weekly guide builds collect, kept in the database so
# searches don't need Overpass, which doesn't answer the server: builds run
# where it does, record what they look up of each route and tile, and export
# it, the Guides workflow publishes it as the routes-data release, and the web
# server imports the newest file every CHECK_EVERY (see RouteStore).
module RouteData
  # What builds record, by cache key prefix: tiles' routes, routes' details,
  # highlights, terrain, and noise.
  KINDS = {
    OverpassService::TILE_KEY => "tile", OverpassService::ROUTE_KEY => "details",
    OverpassService::HIGHLIGHTS_KEY => "highlights", ElevationService::TERRAIN_KEY => "terrain", NoiseService::KEY => "noise"
  }.freeze
  # What's stored of each route, as a column of its own.
  ROUTE_KINDS = %w[details highlights terrain noise].freeze
  RELEASE_URL = "https://api.github.com/repos/jtopgi/transithike/releases/tags/routes-data".freeze
  FILE = /\Aroutes-\d{14}\.ndjson\.gz\z/
  IMPORTED_KEY = "route-data:imported".freeze
  FIRST_WAIT = 1.minute
  CHECK_EVERY = 6.hours
  BATCH = 500
  # Published files are a few megabytes for each city.
  MAX_BYTES = 500.megabytes

  # A build's cache, which records what it looks up of each route and tile.
  class Recorder < ActiveSupport::Cache::MemoryStore
    attr_reader :recorded

    def initialize(...)
      super
      @recorded = Concurrent::Map.new
    end

    private

    def write_entry(key, entry, **options)
      @recorded[key] = entry.value if RouteData.kind(key)
      super
    end
  end

  # The kind of route data a cache key holds, and the tile or route it's for, or nil.
  def self.kind(key)
    prefix = KINDS.keys.find { |each| key.start_with?(each) }
    [KINDS[prefix], key.delete_prefix(prefix)] if prefix
  end

  # Writes what was recorded to path, as gzipped lines of { kind:, key:, value: }.
  def self.export(recorded, path)
    Zlib::GzipWriter.open(path) do |file|
      recorded.each_pair do |cache_key, value|
        kind, key = kind(cache_key)
        file.puts(JSON.generate(kind: kind, key: key, value: value))
      end
    end
  end

  # Stores the lines of an export, as collected at, replacing what was stored
  # for each route and tile, and returns how many it stored.
  def self.import(io, at: Time.current)
    count = 0
    io.each_line.each_slice(BATCH) do |lines|
      lines.map { |line| JSON.parse(line) }.group_by { |row| row["kind"] }.each do |kind, rows|
        store(kind, rows, at)
        count += rows.size
      end
    end
    count
  end

  def self.store(kind, rows, at)
    if kind == "tile"
      RouteTile.upsert_all(rows.map do |row|
        { key: row["key"], routes: row.dig("value", "routes"), collected_at: row.dig("value", "at") || at }
      end.uniq { |tile| tile[:key] })
    elsif ROUTE_KINDS.include?(kind)
      column = kind.to_sym
      routes = rows.map { |row| { osm_id: Integer(row["key"]), column => row["value"], collected_at: at } }
      HikingRoute.upsert_all(routes.uniq { |route| route[:osm_id] }, update_only: [column, :collected_at])
    end
  end

  # Imports the newest published file, unless it was imported already, and returns its name, or nil.
  def self.import_newest(connection: nil, cache: Rails.cache, log: Rails.logger)
    connection ||= Faraday.new(headers: { "User-Agent" => SearchHttp::USER_AGENT }) { |http| http.options.timeout = 120 }
    newest = newest_file(connection)
    return unless newest && cache.read(IMPORTED_KEY) != newest["name"]

    count = import(Zlib::GzipReader.new(StringIO.new(download(connection, newest["browser_download_url"]))))
    cache.write(IMPORTED_KEY, newest["name"])
    log.info("Imported #{count} hiking route records from #{newest['name']}")
    newest["name"]
  end

  # The newest published file, as the release lists it, or nil before any is.
  def self.newest_file(connection)
    response = connection.get(RELEASE_URL)
    return if response.status == 404
    raise SearchErrors::UpstreamError, "The route data couldn't be looked up." unless response.success?

    JSON.parse(response.body).fetch("assets", []).select { |asset| asset["name"].to_s.match?(FILE) }.max_by { |asset| asset["name"] }
  end

  # The file's bytes, following the release's redirect to where it's kept.
  def self.download(connection, url, redirects: 3)
    response = connection.get(url)
    if response.status.between?(300, 399) && redirects.positive?
      return download(connection, response.headers["location"], redirects: redirects - 1)
    end
    raise SearchErrors::UpstreamError, "The route data couldn't be downloaded." unless response.success?
    raise SearchErrors::ResponseTooLarge, "The route data is too large." if response.body.bytesize > MAX_BYTES

    response.body
  end

  # Imports the newest file now and every CHECK_EVERY, in a thread of its own.
  def self.start(log: Rails.logger)
    Thread.new do
      sleep FIRST_WAIT
      loop do
        begin
          Rails.application.executor.wrap { import_newest(log: log) }
        rescue StandardError => error
          log.error("Route data wasn't imported: #{error.class}: #{error.message}")
        end
        sleep CHECK_EVERY
      end
    end
  end
end
