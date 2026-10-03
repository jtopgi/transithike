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
  # Day trips by train take up to four hours from setting out, waiting for the
  # train included, which reaches the scenery farther out while leaving time to hike.
  MAX_TRAVEL_MINUTES = 240
  # Stations reached by then leave time to walk to a route within MAX_TRAVEL_MINUTES.
  STATION_MINUTES = MAX_TRAVEL_MINUTES - 30
  # Commuter, regional, and intercity trains, which take city dwellers out for
  # the day. Transitous's RAIL also means the subway, and its METRO suburban
  # trains, so neither is named.
  TRAIN_MODES = %w[HIGHSPEED_RAIL LONG_DISTANCE NIGHT_RAIL REGIONAL_FAST_RAIL REGIONAL_RAIL SUBURBAN].freeze
  # City rapid transit, the subway and light rail: city dwellers already know the hikes it reaches.
  CITY_MODES = %w[SUBWAY TRAM].freeze
  # Planned trips ride trains, with the subway or light rail to reach them,
  # rather than buses or coaches that would get there sooner: these are day
  # trips by train. Only where no such trip goes is any transit taken.
  TRIP_MODES = (TRAIN_MODES + CITY_MODES).freeze
  # Trains are boarded at the busiest stations transit reaches within the first
  # of these many minutes whose list isn't too long; where every stop within an
  # hour is too many to list, stations within 40 or 25 minutes are.
  HUB_LIST_MINUTES = [60, 40, 25].freeze
  # Searches remember for a day which list fits for an area.
  HUB_LIST_CACHE_TTL = 1.day
  # At most this many stations are boarded at, each at least HUB_SPACING_METERS
  # from the others, and none that trains from an earlier one reach within
  # HUB_SLACK_MINUTES of getting there directly.
  MAX_HUBS = 3
  HUB_SPACING_METERS = 1_000
  HUB_SLACK_MINUTES = 10
  # Where a hub's trains reach too many stations to list in the time left, as
  # across Switzerland, stations within 120 or 80 minutes of boarding are
  # listed instead, and searches remember for a day which limit fits an area.
  RIDE_LIMITS = [nil, 120, 80].freeze
  # Weekend timetables rarely change, so a day's stations are shared for hours.
  RAIL_CACHE_TTL = 6.hours
  # Trips back may ride this much longer than the trip there, for a slower
  # connection home or a wait at a transfer, but no longer.
  BACK_RIDE_FACTOR = 1.25
  BACK_RIDE_SLACK = 15.minutes
  # A ride has to save about this long to be worth taking: when choosing
  # between trips, each ride counts this much longer.
  RIDE_COST = 10.minutes
  # A ride at either end of a trip is walked instead when the walk takes at
  # most this long and arrives at most RIDE_COST later, or leaves at most that
  # much sooner, as walking home from the station rather than riding a bus does.
  MAX_SWAP_WALK_MINUTES = 20
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

  # The train stations reachable from the origin by riding a train, as
  # [latitude, longitude, minutes], quickest first. Trains are boarded at up to
  # MAX_HUBS of the busiest stations reached by subway, bus, or on foot, so the
  # trip there may start on any transit. Raises when transit can't be looked up.
  def self.rail_stations(origin:, departure_time:, connection: nil, cache: Rails.cache)
    key = "transitous:rail:v3:#{origin.latitude.round(3)}:#{origin.longitude.round(3)}:#{departure_time.utc.iso8601}"
    cached = cache.read(key)
    return cached if cached

    connection ||= SearchHttp.connection(ONE_TO_ALL_URL, timeout: 15)
    stations, reached, boarded, error = {}, {}, [], nil
    hubs(origin, departure_time, connection, cache).each do |hub|
      break if boarded.size == MAX_HUBS
      next if reached.fetch(hub[:key], Float::INFINITY) <= hub[:minutes] + HUB_SLACK_MINUTES ||
        boarded.any? { |other| OverpassService.distance(other[:latitude], other[:longitude], hub[:latitude], hub[:longitude]) < HUB_SPACING_METERS }

      boarded << hub
      begin
        ridden = rides(origin, hub, departure_time, connection, cache)
      rescue SearchErrors::UpstreamError => failure
        error ||= failure
        next
      end
      ridden.select { |stop| stop[:train] }.each do |stop|
        minutes = hub[:minutes] + stop[:minutes]
        reached[stop[:key]] = [reached.fetch(stop[:key], minutes), minutes].min
        # Stations the hub itself stands for are walked to, not reached by train.
        next if stop[:rides].zero? || stations[stop[:key]]&.last&.<=(minutes)

        stations[stop[:key]] = [stop[:latitude], stop[:longitude], minutes]
      end
    end
    raise error if error && stations.empty?

    stations = stations.values.sort_by(&:last)
    # A list missing some hub's trains is not shared.
    cache.write(key, stations, expires_in: RAIL_CACHE_TTL) unless error
    stations
  end

  # The stops trains reach from the hub within the first RIDE_LIMITS limit
  # whose list isn't too long.
  def self.rides(origin, hub, departure_time, connection, cache)
    list_key = "transitous:ride-list:v1:#{origin.latitude.round(1)}:#{origin.longitude.round(1)}"
    first = cache.read(list_key).to_i
    params = { one: hub[:id] || format("%.7f,%.7f", hub[:latitude], hub[:longitude]),
      time: (departure_time + hub[:minutes].minutes).utc.iso8601, transitModes: TRAIN_MODES.join(",") }
    RIDE_LIMITS.each_with_index.drop(first).each do |limit, index|
      stops = reachable(connection, params.merge(maxTravelTime: [STATION_MINUTES - hub[:minutes], limit].compact.min))
      cache.write(list_key, index, expires_in: HUB_LIST_CACHE_TTL) if index > first
      return stops
    rescue SearchErrors::ResponseTooLarge
      raise if index == RIDE_LIMITS.size - 1
    end
  end

  # The train stations reached from the origin by any transit within the first
  # HUB_LIST_MINUTES list that isn't too long, busiest first. Where even the
  # last is too long, there are none for a day.
  def self.hubs(origin, departure_time, connection, cache)
    list_key = "transitous:hub-list:v1:#{origin.latitude.round(1)}:#{origin.longitude.round(1)}"
    first = cache.read(list_key).to_i
    HUB_LIST_MINUTES.each_with_index.drop(first).each do |minutes, index|
      stops = reachable(connection, one: place(origin), time: departure_time.utc.iso8601, maxTravelTime: minutes)
      cache.write(list_key, index, expires_in: HUB_LIST_CACHE_TTL) if index > first
      return stops.select { |stop| stop[:train] }.sort_by { |stop| [-stop[:importance], stop[:minutes]] }
    rescue SearchErrors::ResponseTooLarge
      next
    end
    cache.write(list_key, HUB_LIST_MINUTES.size, expires_in: HUB_LIST_CACHE_TTL)
    []
  end

  # Every stop transit reaches, as { key:, id:, latitude:, longitude:, minutes:,
  # rides:, importance:, train: }, skipping malformed entries. key is the stop's
  # id, or its coordinates when it has none; importance ranks how busy it is.
  def self.reachable(connection, params)
    data = SearchHttp.json { connection.get { |request| request.params = params } }
    raise SearchErrors::UpstreamError, INVALID_RESPONSE unless data["all"].is_a?(Array)

    data["all"].filter_map do |reachable|
      point = reachable["place"] if reachable.is_a?(Hash)
      next unless point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"]) &&
        valid_trip?(reachable) && reachable["k"].is_a?(Integer) && !reachable["k"].negative?

      id = point["stopId"] if point["stopId"].is_a?(String) && point["stopId"].length.between?(1, 200)
      importance = point["importance"].is_a?(Numeric) && point["importance"].finite? ? point["importance"] : 0
      { key: id || [point["lat"], point["lon"]], id: id, latitude: point["lat"], longitude: point["lon"],
        minutes: reachable["duration"], rides: reachable["k"], importance: importance,
        train: Array(point["modes"]).intersect?(TRAIN_MODES) }
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
  # agency:, headsign:, from:, to:, from_name:, to_name:, departure:, arrival: }] }
  # with ISO 8601 times, the ids and names of the stops each leg rides between
  # (nil when unknown), and only the legs on transit (none for walking the whole
  # way), or nil when there is none. It leaves at time and arrives soonest.
  def self.journey(origin:, destination:, time:, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: time.utc.iso8601,
      arriveBy: false, timetableView: false, detailedLegs: false, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    latest = (time + MAX_TRAVEL_MINUTES.minutes).utc.iso8601
    cache.fetch("transitous:journey:v5:#{params.values_at(:fromPlace, :toPlace, :time).join(':')}", expires_in: TRIP_CACHE_TTL) do
      connection ||= SearchHttp.connection(PLAN_URL, timeout: 10)
      by_train(connection, params, leave_after: time) { |journey| journey[:arrival] <= latest }
        .min_by { |journey| costed_arrival(journey) }
    end
  end

  # The trips back from a route to the origin, by the same way as the journey
  # there, as { back:, last:, same_way:, trips: }, each trip like #journey's or nil.
  # back is home soonest while leaving at earliest or later, as after a hike, and
  # last leaves latest while home by the deadline; trips are all those from back
  # to last, in order. The same way rides the journey's trains back between the
  # same stations, with the same kinds of transit or the city's subway and light
  # rail. Trips back that ride much longer than the journey there, as slow buses
  # late in the evening do, don't count. Where the same way has no trip back
  # after earliest, any way does, and same_way is false; it is nil when there is
  # no journey to follow, or follow is false, as for trips back from the far end
  # of a route. Only when nothing leaves after earliest is the way back the last
  # trip before it.
  def self.ways_back(origin:, destination:, like:, earliest:, deadline:, follow: true, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: deadline.utc.iso8601, arriveBy: true,
      # Every trip that leaves from earliest until the last one is listed.
      timetableView: true, searchWindow: (deadline - earliest).clamp(1.hour, 14.hours).to_i,
      detailedLegs: false, maxPreTransitTime: MAX_POST_TRANSIT_SECONDS, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    # The planner looks to earlier days when nothing gets home that evening, so trips home over a day before the deadline are left out.
    day = (deadline - 1.day).utc.iso8601
    trips_for = lambda do |query|
      key = Digest::SHA256.hexdigest(query.merge(earliest: earliest.utc.iso8601).to_json)
      cache.fetch("transitous:ways-back:v4:#{key}", expires_in: TRIP_CACHE_TTL) do
        connection ||= SearchHttp.connection(PLAN_URL, timeout: 15)
        plan(connection, query, leave_after: earliest, arrive_by: deadline).select { |trip| trip[:arrival].between?(day, params[:time]) }
      end
    end
    longest = ride_seconds(like) * BACK_RIDE_FACTOR + BACK_RIDE_SLACK if like
    swift = ->(trips) { longest ? trips.select { |trip| ride_seconds(trip) <= longest } : trips }

    constrained = follow ? params.merge(same_way(like)) : params
    same = []
    unless constrained == params
      same = begin
        swift.(trips_for.(constrained))
      rescue SearchErrors::UpstreamError
        # The planner may not know a station, so any way back is looked up instead.
        []
      end
      back = first_home(same, earliest)
      return { back: back, last: last_trip(same), same_way: true, trips: timetable(same, back[:departure]) } if back
    end
    trips = trips_for.(params.merge(by_train_params))
    # Only where no train goes home after the hike is any transit taken.
    trips = trips_for.(params) if trips.none? { |trip| trip[:departure] >= earliest.utc.iso8601 }
    other_way = (false unless constrained == params)
    after = trips.select { |trip| trip[:departure] >= earliest.utc.iso8601 }
    # A slow trip after the hike still beats a quick one that leaves before it's over.
    pool = swift.(after).presence || after
    if pool.any?
      back = first_home(pool, earliest)
      return { back: back, last: last_trip(pool), same_way: other_way, trips: timetable(pool, back[:departure]) }
    end

    # When no way back leaves after the hike, the last one is still the one to take, the same way if it can be.
    before = same.presence || swift.(trips).presence || trips
    last = last_trip(before)
    { back: last, last: last, same_way: same.any? || other_way, trips: [last].compact }
  end

  # The trips there that leave from time until latest, like #journey's and in
  # order, leaving out any that ride much longer than the quickest; by train
  # unless by_train is false, as when the journey there isn't.
  def self.departures(origin:, destination:, time:, latest:, by_train: true, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: time.utc.iso8601, arriveBy: false,
      timetableView: true, searchWindow: (latest - time).clamp(1.hour, 12.hours).to_i, detailedLegs: false,
      maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    key = Digest::SHA256.hexdigest(params.merge(latest: latest.utc.iso8601, by_train: by_train).to_json)
    trips = cache.fetch("transitous:departures:v2:#{key}", expires_in: TRIP_CACHE_TTL) do
      connection ||= SearchHttp.connection(PLAN_URL, timeout: 15)
      leaving = ->(trip) { trip[:departure].between?(params[:time], latest.utc.iso8601) }
      if by_train
        by_train(connection, params, leave_after: time, &leaving)
      else
        plan(connection, params, leave_after: time).select(&leaving)
      end
    end
    quickest = trips.map { |trip| ride_seconds(trip) }.min
    timetable(trips.select { |trip| ride_seconds(trip) <= quickest * BACK_RIDE_FACTOR + BACK_RIDE_SLACK.to_i })
  end

  # The trips that leave from the time given on, in order, without any that
  # leave at the same time as another but arrive later, by costed_arrival.
  def self.timetable(trips, from = nil)
    trips.select { |trip| from.nil? || trip[:departure] >= from }.group_by { |trip| trip[:departure] }
      .map { |_, same| same.min_by { |trip| costed_arrival(trip) } }.sort_by { |trip| [trip[:departure], trip[:arrival]] }
  end

  # The trip home soonest by costed_arrival that leaves at earliest or later,
  # riding the least when several are home at once.
  def self.first_home(trips, earliest)
    trips.select { |trip| trip[:departure] >= earliest.utc.iso8601 }
      .min_by { |trip| [costed_arrival(trip), -Time.iso8601(trip[:departure]).to_i] }
  end

  # The trip that leaves latest, and of those, the one home soonest by costed_arrival.
  def self.last_trip(trips)
    trips.min_by { |trip| [-Time.iso8601(trip[:departure]).to_i, costed_arrival(trip)] }
  end

  # When a trip arrives, with each ride counted RIDE_COST longer.
  def self.costed_arrival(trip)
    Time.iso8601(trip[:arrival]) + trip[:legs].size * RIDE_COST
  end

  # The trips a plan finds on TRIP_MODES that the block keeps, or where there
  # are none, those it finds on any transit; bounds are #plan's.
  def self.by_train(connection, params, **bounds, &keep)
    plan(connection, params.merge(by_train_params), **bounds).select(&keep).presence ||
      plan(connection, params, **bounds).select(&keep)
  end

  # Whether a trip rides only TRIP_MODES, as trips by train do.
  def self.by_train?(trip)
    trip[:legs].all? { |leg| TRIP_MODES.include?(leg[:mode]) }
  end

  # Without buses, the walk from where a trip starts may be as long as the one to where it ends.
  def self.by_train_params
    { transitModes: TRIP_MODES.join(","), maxPreTransitTime: MAX_POST_TRANSIT_SECONDS }
  end

  def self.ride_seconds(trip)
    Time.iso8601(trip[:arrival]) - Time.iso8601(trip[:departure])
  end

  # The via stations and transit modes that keep a trip back to the journey's
  # way, as plan parameters: its trains ridden back from the station where they
  # stopped to the one where they started. Stations are the same both ways,
  # while buses often stop across the street, so only the kinds of transit
  # keep a journey without trains to its way.
  def self.same_way(journey)
    legs = Array(journey && journey[:legs])
    return {} if legs.empty?

    trains = legs.select { |leg| TRAIN_MODES.include?(leg[:mode]) }
    via = [trains.last&.dig(:to), trains.first&.dig(:from)].compact.uniq
    modes = (legs.map { |leg| leg[:mode] } + CITY_MODES).uniq
    { via: via.join(",").presence, transitModes: modes.join(",") }.compact
  end

  # The trips in a plan response, skipping malformed ones. A ride at either end
  # is only walked instead when the trip still leaves at leave_after or later
  # and gets there by arrive_by, as the plan's caller asks.
  def self.plan(connection, params, leave_after: nil, arrive_by: nil)
    data = SearchHttp.json { connection.get { |request| request.params = params } }
    journeys = data.values_at("itineraries", "direct")
    raise SearchErrors::UpstreamError, INVALID_RESPONSE unless journeys.all?(Array)

    ends = params.values_at(:fromPlace, :toPlace).map { |place| coordinates(place) }
    journeys.flatten(1).filter_map { |journey| journey_summary(journey, *ends, leave_after: leave_after, arrive_by: arrive_by) }
  end

  # A trip's times and rides, with a ride at either end walked instead where
  # walk_ends says, from and to being where the trip starts and ends.
  def self.journey_summary(journey, from = nil, to = nil, leave_after: nil, arrive_by: nil)
    return unless journey.is_a?(Hash) && journey["legs"].is_a?(Array) && journey["legs"].all?(Hash)

    departure, arrival = journey.values_at("startTime", "endTime").map { |time| parse_time(time) }
    return unless departure && arrival && arrival >= departure

    legs = journey["legs"].select { |leg| leg["mode"].is_a?(String) && leg["mode"].match?(/\A[A-Z_]{1,30}\z/) }
      .reject { |leg| STREET_MODES.include?(leg["mode"]) }
    departure, arrival = walk_ends(legs, departure, arrival, from, to, leave_after, arrive_by)
    { departure: departure.utc.iso8601, arrival: arrival.utc.iso8601, legs: legs.map do |leg|
      # Trains are known by their lines, such as "Port Jervis Line", rather than codes like "MNBNP".
      names = leg.values_at("routeShortName", "routeLongName")
      names.reverse! if TRAIN_MODES.include?(leg["mode"])
      { mode: leg["mode"], name: text(names.first) || text(names.last) || text(leg["displayName"]),
        agency: text(leg["agencyName"]), headsign: text(leg["headsign"]), from: stop_id(leg["from"]), to: stop_id(leg["to"]),
        from_name: stop_name(leg["from"]), to_name: stop_name(leg["to"]),
        departure: parse_time(leg["startTime"])&.utc&.iso8601, arrival: parse_time(leg["endTime"])&.utc&.iso8601 }
    end }
  end

  # Drops the last of a trip's rides when walking from where the ride before it
  # stops takes at most MAX_SWAP_WALK_MINUTES and arrives at most RIDE_COST
  # later, by arrive_by, and the first likewise, walking to where the next ride
  # leaves, at leave_after or later unless the trip leaves before then anyway.
  # Returns the trip's [departure, arrival]. At least one ride is kept.
  def self.walk_ends(rides, departure, arrival, from, to, leave_after = nil, arrive_by = nil)
    if rides.size > 1 && (walk = walk_minutes(point(rides[-2]["to"]), to)) && (off = parse_time(rides[-2]["endTime"]))
      home = off + walk.minutes
      if walk <= MAX_SWAP_WALK_MINUTES && home <= arrival + RIDE_COST && (arrive_by.nil? || home <= arrive_by)
        rides.pop
        arrival = home
      end
    end
    if rides.size > 1 && (walk = walk_minutes(from, point(rides[1]["from"]))) && (on = parse_time(rides[1]["startTime"]))
      leave = on - walk.minutes
      if walk <= MAX_SWAP_WALK_MINUTES && leave >= departure - RIDE_COST &&
          (leave_after.nil? || leave >= leave_after || departure < leave_after)
        rides.shift
        departure = leave
      end
    end
    [departure, arrival]
  end

  # Minutes to walk between [latitude, longitude] points, as TransitAccess estimates, or nil.
  def self.walk_minutes(from, to)
    (OverpassService.distance(*from, *to) * TransitAccess::DETOUR / TransitAccess::WALK_METERS_PER_MINUTE).ceil if from && to
  end

  def self.point(place)
    [place["lat"], place["lon"]] if place.is_a?(Hash) && SearchHttp.coordinates?(place["lat"], place["lon"])
  end

  # The [latitude, longitude] in a "latitude,longitude" place, or nil.
  def self.coordinates(text)
    latitude, longitude = text.to_s.split(",", 2).map { |part| Float(part, exception: false) }
    [latitude, longitude] if SearchHttp.coordinates?(latitude, longitude)
  end

  def self.stop_name(place)
    text(place["name"]) if place.is_a?(Hash)
  end

  # A stop's id, which plans can be asked to go via, or nil.
  def self.stop_id(place)
    id = place["stopId"] if place.is_a?(Hash)
    id if id.is_a?(String) && id.match?(/\A[^,\s]{1,200}\z/)
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
  # modes limits the transit taken, such as to CITY_MODES.
  def self.trips(origin:, destinations:, departure_time:, modes: nil, connection: nil, cache: Rails.cache)
    return [] if destinations.empty?

    params = {
      one: place(origin, ";"), many: destinations.map { |destination| place(destination, ";") }.join(","),
      time: departure_time.utc.iso8601, maxTravelTime: MAX_TRAVEL_MINUTES, maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    params[:transitModes] = modes.join(",") if modes
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
