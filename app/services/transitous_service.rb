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
  # Trains, subways, trams, and ferries, which still show where transit reaches
  # where every stop is too many to list.
  RAIL_MODES = %w[RAIL HIGHSPEED_RAIL LONG_DISTANCE NIGHT_RAIL REGIONAL_FAST_RAIL REGIONAL_RAIL SUBURBAN SUBWAY
    METRO TRAM FERRY FUNICULAR AERIAL_LIFT CABLE_CAR].freeze
  # Each list is shorter than the one before: every reachable stop, then those
  # reached by rail and ferries, then those reached so within 90 minutes.
  STOP_LISTS = [{ minutes: REACHABLE_STOP_MINUTES }, { minutes: REACHABLE_STOP_MINUTES, modes: RAIL_MODES },
    { minutes: 90, modes: RAIL_MODES }].freeze
  # Searches remember for a day which list fits for an area.
  STOP_LIST_CACHE_TTL = 1.day
  # Legs in these modes are on foot or by private vehicle, not on transit.
  STREET_MODES = %w[WALK BIKE RENTAL CAR HGV CAR_PARKING CAR_DROPOFF ODM RIDE_SHARING FLEX].freeze
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

  # Stops reachable from the origin, as [latitude, longitude, minutes, rides,
  # station], where station is true for stops served by rail or ferries; or nil
  # where transit is too dense to list them.
  def self.reachable_stops(origin:, departure_time:, connection: nil, cache: Rails.cache)
    list_key = "transitous:stop-list:v1:#{origin.latitude.round(1)}:#{origin.longitude.round(1)}"
    first = cache.read(list_key).to_i
    connection ||= SearchHttp.connection(ONE_TO_ALL_URL, timeout: 15)
    STOP_LISTS.each_with_index.drop(first).each do |list, index|
      stops = fetch_stops(origin, departure_time, list, connection)
      cache.write(list_key, index, expires_in: STOP_LIST_CACHE_TTL) if index > first
      return stops
    rescue SearchErrors::ResponseTooLarge
      next
    end
    cache.write(list_key, STOP_LISTS.size, expires_in: STOP_LIST_CACHE_TTL)
    nil
  end

  def self.fetch_stops(origin, departure_time, list, connection)
    params = { one: place(origin), time: departure_time.utc.iso8601, maxTravelTime: list[:minutes] }
    params[:transitModes] = list[:modes].join(",") if list[:modes]
    data = SearchHttp.json { connection.get { |request| request.params = params } }
    raise SearchErrors::UpstreamError, INVALID_RESPONSE unless data["all"].is_a?(Array)

    data["all"].filter_map do |reachable|
      point = reachable["place"] if reachable.is_a?(Hash)
      next unless point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"]) &&
        valid_trip?(reachable) && reachable["k"].is_a?(Integer) && !reachable["k"].negative?

      [point["lat"], point["lon"], reachable["duration"], reachable["k"], Array(point["modes"]).intersect?(RAIL_MODES)]
    end
  end

  # The latest time to leave each destination and still be back at the origin
  # by the deadline, in one request, or nil where nothing gets back in time.
  # Only departures at least earliest_return are considered.
  def self.latest_returns(origin:, destinations:, deadline:, earliest_return:, connection: nil, cache: Rails.cache)
    return [] if destinations.empty?

    params = {
      one: place(origin, ";"), many: destinations.map { |destination| place(destination, ";") }.join(","),
      time: deadline.utc.iso8601, arriveBy: true, maxTravelTime: ((deadline - earliest_return) / 60).floor.clamp(1, 900),
      maxPreTransitTime: MAX_POST_TRANSIT_SECONDS, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    # Seconds before the deadline, cached rather than times.
    margins = cache.fetch("transitous:returns:v1:#{Digest::SHA256.hexdigest(params.to_json)}", expires_in: TRIP_CACHE_TTL) do
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
        [*options.map { |option| option["duration"] }, walk&.fetch("duration")].compact.min
      end
    end
    margins.map { |seconds| deadline - seconds if seconds }
  end

  # A trip for showing its legs, as { departure:, arrival:, legs: [{ mode:, name:,
  # agency:, headsign: }] } with ISO 8601 times and only the legs on transit
  # (none for walking the whole way), or nil when there is none. By default it
  # leaves at time and arrives soonest; with arrive_by, it arrives by time and
  # leaves as late as possible.
  def self.journey(origin:, destination:, time:, arrive_by: false, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: time.utc.iso8601,
      arriveBy: arrive_by, timetableView: false, detailedLegs: false, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    # Coming back starts with the walk from the route to a stop.
    params[:maxPreTransitTime] = MAX_POST_TRANSIT_SECONDS if arrive_by
    cache_key = "transitous:journey:v1:#{params.values_at(:fromPlace, :toPlace, :time, :arriveBy).join(':')}"
    cache.fetch(cache_key, expires_in: TRIP_CACHE_TTL) do
      connection ||= SearchHttp.connection(PLAN_URL, timeout: 10)
      data = SearchHttp.json { connection.get { |request| request.params = params } }
      journeys = data.values_at("itineraries", "direct")
      raise SearchErrors::UpstreamError, INVALID_RESPONSE unless journeys.all?(Array)

      summaries = journeys.flatten(1).filter_map { |journey| journey_summary(journey) }
      if arrive_by
        summaries.select { |journey| journey[:arrival] <= params[:time] }.max_by { |journey| journey[:departure] }
      else
        summaries.min_by { |journey| journey[:arrival] }
      end
    end
  end

  def self.journey_summary(journey)
    return unless journey.is_a?(Hash) && journey["legs"].is_a?(Array) && journey["legs"].all?(Hash)

    departure, arrival = journey.values_at("startTime", "endTime").map { |time| parse_time(time) }
    return unless departure && arrival && arrival >= departure

    legs = journey["legs"].select { |leg| leg["mode"].is_a?(String) && leg["mode"].match?(/\A[A-Z_]{1,30}\z/) }
      .reject { |leg| STREET_MODES.include?(leg["mode"]) }
    { departure: departure.utc.iso8601, arrival: arrival.utc.iso8601, legs: legs.map do |leg|
      { mode: leg["mode"], name: text(leg["routeShortName"]) || text(leg["routeLongName"]) || text(leg["displayName"]),
        agency: text(leg["agencyName"]), headsign: text(leg["headsign"]) }
    end }
  end

  def self.parse_time(value)
    Time.iso8601(value) if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def self.text(value)
    value.squish.truncate(60) if value.is_a?(String) && value.strip.present?
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
