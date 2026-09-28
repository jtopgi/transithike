require "uri"

module OverpassService
  URL = "https://overpass-api.de/api/interpreter"
  RADIUS_METERS = 25_000
  MAX_RESULTS = 100
  MAX_TRANSIT_ROUTES = 10
  CACHE_TTL = 15.minutes
  METERS_PER_MILE = 1609.344
  Trail = Struct.new(:name, :summary, :latitude, :longitude, :length, :osm_id,
    :duration, :origin, keyword_init: true)

  def self.get_trails(lat:, lon:, maximum_length:, connection: nil, cache: Rails.cache)
    unless SearchHttp.coordinates?(lat, lon)
      raise SearchErrors::InvalidInput, "The origin does not have valid coordinates."
    end

    query = <<~QUERY
      [out:json][timeout:20][maxsize:8388608];
      relation(around:#{RADIUS_METERS},#{lat},#{lon})["type"="route"]["route"="hiking"];
      out geom #{MAX_RESULTS};
    QUERY
    connection ||= SearchHttp.connection(URL, timeout: 25)
    trails = nil
    cache_key = "overpass:hiking:v1:#{RADIUS_METERS}:#{MAX_RESULTS}:#{lat.to_f}:#{lon.to_f}"
    data = cache.fetch(cache_key, expires_in: CACHE_TTL) do
      response = SearchHttp.json do
        connection.post do |request|
          request.body = URI.encode_www_form(data: query)
          request.headers["Content-Type"] = "application/x-www-form-urlencoded"
        end
      end
      unless response["elements"].is_a?(Array) && !response.key?("remark")
        raise SearchErrors::UpstreamError, "The hiking route provider returned an incomplete response."
      end
      # Validate before caching; retain only OSM data, never mutable transit results.
      trails = response["elements"].first(MAX_RESULTS).filter_map { |element| map_trail(element) }
      response
    end
    trails ||= data["elements"].first(MAX_RESULTS).filter_map { |element| map_trail(element) }

    trails.select { |trail| trail.length <= maximum_length }
      .sort_by { |trail| distance(lat, lon, trail.latitude, trail.longitude) }
      .first(MAX_TRANSIT_ROUTES)
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
      osm_id: element["id"]
    )
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
