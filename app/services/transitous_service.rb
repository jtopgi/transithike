require "digest"
require "time"

# Public-transit routing from Transitous (https://transitous.org), a free,
# community-run MOTIS instance. Its usage policy requires an identifying
# User-Agent (see SearchHttp), attribution, open-source non-commercial use, and
# contacting the maintainers before sending heavier routing traffic.
module TransitousService
  ONE_TO_MANY_URL = "https://api.transitous.org/api/experimental/one-to-many-intermodal"
  ONE_TO_ALL_URL = "https://api.transitous.org/api/v1/one-to-all"
  PLAN_URL = "https://api.transitous.org/api/v6/plan"
  REVERSE_GEOCODE_URL = "https://api.transitous.org/api/v1/reverse-geocode"
  SOURCES_URL = "https://transitous.org/sources/"
  # Route starts are often farther than the default 15-minute walk from a stop.
  MAX_POST_TRANSIT_SECONDS = 30 * 60
  MAX_TRAVEL_MINUTES = 3 * 60
  # Stops reached by then leave time to walk to a route within MAX_TRAVEL_MINUTES.
  REACHABLE_STOP_MINUTES = MAX_TRAVEL_MINUTES - 30
  # Where transit is too dense to list every reachable stop, searches skip the list for a day.
  DENSE_CACHE_TTL = 1.day
  TRIP_CACHE_TTL = 15.minutes
  AREA_CACHE_TTL = 30.days
  TIME_ZONE_FORMAT = %r{\A[A-Za-z]+(?:/[A-Za-z0-9_+-]+)*\z}
  INVALID_RESPONSE = "The transit provider returned an invalid response."

  # The time zone and a readable area for coordinates, e.g.
  # { time_zone: "America/Los_Angeles", area: "Seattle, Washington, United States" }.
  def self.area(latitude, longitude, connection: nil, cache: Rails.cache)
    cache.fetch("transitous:area:v1:#{latitude.round(2)}:#{longitude.round(2)}", expires_in: AREA_CACHE_TTL) do
      connection ||= SearchHttp.connection(REVERSE_GEOCODE_URL)
      matches = SearchHttp.json(Array) do
        connection.get { |request| request.params = { place: format("%.5f,%.5f", latitude, longitude) } }
      end
      match = matches.find { |candidate| candidate.is_a?(Hash) } || {}
      zone = match["tz"]
      { time_zone: zone.is_a?(String) && zone.match?(TIME_ZONE_FORMAT) ? zone : nil, area: area_label(match["areas"]) }
    end
  end

  # Every stop reachable from the origin, as [latitude, longitude, minutes, rides],
  # or nil where transit is too dense to list them all.
  def self.reachable_stops(origin:, departure_time:, connection: nil, cache: Rails.cache)
    dense_key = "transitous:dense:v1:#{origin.latitude.round(1)}:#{origin.longitude.round(1)}"
    return if cache.read(dense_key)

    connection ||= SearchHttp.connection(ONE_TO_ALL_URL, timeout: 15)
    data = SearchHttp.json do
      connection.get do |request|
        request.params = { one: place(origin), time: departure_time.utc.iso8601, maxTravelTime: REACHABLE_STOP_MINUTES }
      end
    end
    raise SearchErrors::UpstreamError, INVALID_RESPONSE unless data["all"].is_a?(Array)

    data["all"].filter_map do |reachable|
      point = reachable["place"] if reachable.is_a?(Hash)
      next unless point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"]) &&
        valid_trip?(reachable) && reachable["k"].is_a?(Integer) && !reachable["k"].negative?

      [point["lat"], point["lon"], reachable["duration"], reachable["k"]]
    end
  rescue SearchErrors::ResponseTooLarge
    cache.write(dense_key, true, expires_in: DENSE_CACHE_TTL)
    nil
  end

  # The fastest trip to each destination, in one request: { duration: seconds,
  # transfers: count, or nil for walking the whole way }, or nil when unreachable.
  def self.trips(origin:, destinations:, departure_time:, connection: nil, cache: Rails.cache)
    return [] if destinations.empty?

    params = {
      one: place(origin, ";"), many: destinations.map { |destination| place(destination, ";") }.join(","),
      time: departure_time.utc.iso8601, maxTravelTime: MAX_TRAVEL_MINUTES, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    cache.fetch("transitous:trips:v1:#{Digest::SHA256.hexdigest(params.to_json)}", expires_in: TRIP_CACHE_TTL) do
      connection ||= SearchHttp.connection(ONE_TO_MANY_URL, timeout: 20)
      data = SearchHttp.json { connection.get { |request| request.params = params } }
      transit, walking = data.values_at("transit_durations", "street_durations")
      unless transit.is_a?(Array) && transit.size == destinations.size &&
          transit.all? { |options| options.is_a?(Array) && options.all? { |option| valid_trip?(option, "transfers") } }
        raise SearchErrors::UpstreamError, INVALID_RESPONSE
      end

      walking = [] unless walking.is_a?(Array)
      transit.each_with_index.map do |options, index|
        walk = walking[index] if walking[index].is_a?(Hash) && valid_trip?(walking[index])
        fastest([*options.map { |option| travel(option["duration"], option["transfers"]) }, (travel(walk["duration"]) if walk)])
      end
    end
  end

  # The fastest trip to one destination; slower, but uses the stable planning API.
  def self.trip(origin:, destination:, departure_time:, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: departure_time.utc.iso8601,
      arriveBy: false, timetableView: false, detailedLegs: false,
      maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    cache_key = "transitous:plan:v3:#{params.values_at(:fromPlace, :toPlace, :time).join(':')}"
    cache.fetch(cache_key, expires_in: TRIP_CACHE_TTL) do
      connection ||= SearchHttp.connection(PLAN_URL, timeout: 10)
      data = SearchHttp.json { connection.get { |request| request.params = params } }
      itineraries, walks = data.values_at("itineraries", "direct")
      unless [itineraries, walks].all? { |list| list.is_a?(Array) && list.all? { |journey| valid_trip?(journey) } } &&
          itineraries.all? { |itinerary| itinerary["transfers"].is_a?(Integer) }
        raise SearchErrors::UpstreamError, INVALID_RESPONSE
      end

      # Direct walks count too: transit slower than the fastest walk is omitted.
      fastest(itineraries.map { |itinerary| travel(itinerary["duration"], itinerary["transfers"]) } +
        walks.map { |walk| travel(walk["duration"]) })
    end
  end

  # For example "Seattle, Washington, United States", from the most local area up.
  def self.area_label(areas)
    names = Array(areas).select { |area| area.is_a?(Hash) && area["name"].is_a?(String) }
    local = names.find { |area| area["default"] == true }
    parts = [local, *[4, 2].map { |level| names.find { |area| area["adminLevel"] == level } }]
    parts.compact.map { |area| area["name"].strip }.reject(&:empty?).uniq.join(", ").presence
  end

  def self.place(location, separator = ",")
    unless SearchHttp.coordinates?(location.latitude, location.longitude)
      raise SearchErrors::InvalidInput, "The route does not have valid coordinates."
    end

    format("%.7f#{separator}%.7f", location.latitude, location.longitude)
  end

  def self.travel(duration, transfers = nil)
    { duration: duration, transfers: transfers }
  end

  def self.fastest(trips)
    trips.compact.min_by { |candidate| candidate[:duration] }
  end

  def self.valid_trip?(value, transfers_key = nil)
    duration = value.is_a?(Hash) ? value["duration"] : nil
    duration.is_a?(Numeric) && duration.finite? && duration >= 0 &&
      (transfers_key.nil? || (value[transfers_key].is_a?(Integer) && !value[transfers_key].negative?))
  end
end
