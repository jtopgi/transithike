module TrailsService
  Result = Struct.new(:location, :arrival_time, :trails, keyword_init: true)
  ARRIVAL_WINDOW = 7.days

  # arrival is [year, month, day, hour, minute] on the clock at the origin.
  def self.search(origin:, arrival:, maximum_length:, transit: TransitousService, hiking: OverpassService)
    location = transit.geocode(origin)
    raise SearchErrors::InvalidInput, "We could not find that origin. Please enter a more specific location." unless location

    arrival_time = local_time(location.time_zone, arrival)
    unless arrival_time > Time.current && arrival_time <= ARRIVAL_WINDOW.from_now
      raise SearchErrors::InvalidInput, "Choose an arrival time in the future, within the next 7 days. " \
        "Times are local to your origin (#{arrival_time.zone})."
    end

    trails = hiking.get_trails(lat: location.latitude, lon: location.longitude, maximum_length: maximum_length)
      .first(OverpassService::MAX_TRANSIT_ROUTES).filter_map do |trail|
        duration = transit.transit_duration(origin: location, destination: trail, arrival_time: arrival_time)
        next if duration.nil?

        trail.duration = duration
        trail.origin = origin
        trail
      end.sort_by(&:duration)
    Result.new(location: location, arrival_time: arrival_time, trails: trails)
  end

  # Falls back to the application time zone (UTC) when the origin's is unknown.
  def self.local_time(time_zone, arrival)
    zone = (ActiveSupport::TimeZone[time_zone] if time_zone) || Time.zone
    zone.local(*arrival)
  end
end
