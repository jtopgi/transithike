require "uri"

module OverpassService
  URL = "https://overpass-api.de/api/interpreter"
  RADIUS_METERS = 25_000
  MAX_RESULTS = 100
  MAX_TRANSIT_ROUTES = 15
  # Longer routes are multi-day trails rather than hikes from a nearby start.
  MAX_LENGTH_MILES = 30
  # Mapped routes rarely change, so nearby searches can share results for hours.
  CACHE_TTL = 6.hours
  PREVIEW_POINTS = 150
  METERS_PER_MILE = 1609.344
  # duration is in seconds; transfers is nil when walking the whole way is fastest.
  Trail = Struct.new(:name, :summary, :latitude, :longitude, :length, :osm_id, :path,
    :distance, :duration, :transfers, :origin, keyword_init: true)

  # The nearest routes to the origin; distance is in miles from the origin.
  def self.get_trails(lat:, lon:, connection: nil, cache: Rails.cache)
    unless SearchHttp.coordinates?(lat, lon)
      raise SearchErrors::InvalidInput, "The origin does not have valid coordinates."
    end

    # Rounding to about 1 km lets nearby searches share one query.
    center = [lat.to_f.round(2), lon.to_f.round(2)]
    cache_key = "overpass:hiking:v2:#{RADIUS_METERS}:#{MAX_RESULTS}:#{center.join(':')}"
    routes = cache.fetch(cache_key, expires_in: CACHE_TTL) do
      fetch_routes(*center, connection || SearchHttp.connection(URL, timeout: 25))
    end

    routes.map { |attributes| Trail.new(**attributes) }
      .each { |trail| trail.distance = distance(lat, lon, trail.latitude, trail.longitude) / METERS_PER_MILE }
      .sort_by(&:distance)
      .first(MAX_TRANSIT_ROUTES)
  end

  def self.fetch_routes(lat, lon, connection)
    query = <<~QUERY
      [out:json][timeout:20][maxsize:8388608];
      relation(around:#{RADIUS_METERS},#{lat},#{lon})["type"="route"]["route"="hiking"];
      out geom #{MAX_RESULTS};
    QUERY
    response = SearchHttp.json do
      connection.post do |request|
        request.body = URI.encode_www_form(data: query)
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
    end
    unless response["elements"].is_a?(Array) && !response.key?("remark")
      raise SearchErrors::UpstreamError, "The hiking route provider returned an incomplete response."
    end

    # Validate before caching, and cache plain OSM attributes: never transit results.
    response["elements"].first(MAX_RESULTS).filter_map { |element| map_trail(element) }
      .select { |trail| trail.length <= MAX_LENGTH_MILES }
      .map { |trail| trail.to_h.compact }
  end

  def self.map_trail(element)
    unless element.is_a?(Hash) && element["type"] == "relation" &&
        element["id"].is_a?(Integer) && element["id"].positive? &&
        element["tags"].is_a?(Hash) && element["members"].is_a?(Array)
      raise SearchErrors::UpstreamError, "The hiking route provider returned an invalid route."
    end
    tags = element["tags"]
    return unless tags["type"] == "route" && tags["route"] == "hiking"

    members = element["members"]
    unless members.all? { |member| member.is_a?(Hash) }
      raise SearchErrors::UpstreamError, "The hiking route provider returned invalid geometry."
    end
    # Nested relations or missing geometry cannot yield a trustworthy length.
    return if members.any? { |member| member["type"] == "relation" }
    ways = members.select { |member| member["type"] == "way" }
    return if ways.empty? || ways.any? { |way| !way["ref"].is_a?(Integer) }
    ways = ways.uniq { |way| way["ref"] }
    return unless ways.all? { |way| valid_geometry?(way["geometry"]) }

    meters = ways.sum do |way|
      way["geometry"].each_cons(2).sum do |first, last|
        distance(first["lat"], first["lon"], last["lat"], last["lon"])
      end
    end
    return unless meters.positive?

    first_way = ways.first
    start = first_way["role"] == "backward" ? first_way["geometry"].last : first_way["geometry"].first
    Trail.new(
      name: tags["name"].is_a?(String) && !tags["name"].strip.empty? ? tags["name"] : "Unnamed hiking route",
      summary: tags["description"].is_a?(String) ? tags["description"] : "A hiking route mapped by OpenStreetMap contributors.",
      latitude: start["lat"], longitude: start["lon"], length: meters / METERS_PER_MILE,
      osm_id: element["id"], path: preview_path(ways)
    )
  end

  # Downsampled [[latitude, longitude], ...] lines, enough to draw a route preview.
  def self.preview_path(ways)
    step = [(ways.sum { |way| way["geometry"].length } / PREVIEW_POINTS.to_f).ceil, 1].max
    ways.map do |way|
      points = way["geometry"].each_slice(step).map(&:first)
      points << way["geometry"].last unless points.last.equal?(way["geometry"].last)
      points.map { |point| [point["lat"].round(5), point["lon"].round(5)] }
    end
  end

  def self.valid_geometry?(geometry)
    geometry.is_a?(Array) && geometry.length >= 2 && geometry.all? do |point|
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
    end
  end

  def self.distance(lat1, lon1, lat2, lon2)
    radians = Math::PI / 180
    a = Math.sin((lat2 - lat1) * radians / 2)**2 +
      Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin((lon2 - lon1) * radians / 2)**2
    6_371_000 * 2 * Math.asin(Math.sqrt(a.clamp(0, 1)))
  end
end
