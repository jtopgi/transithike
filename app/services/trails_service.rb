module TrailsService
  Result = Struct.new(:place, :area, :departure_time, :trails, keyword_init: true)
  # Hikers usually set out in the morning, so late searches plan for the next one.
  LEAVE_NOW_HOURS = 5..14
  MORNING_HOUR = 8

  # origin is text to look up, or a Place chosen from suggestions or the device's location.
  def self.search(origin:, places: PhotonService, transit: TransitousService, hiking: OverpassService)
    place = origin.is_a?(String) ? places.geocode(origin) : origin
    unless place
      raise SearchErrors::InvalidInput, "We could not find that starting point. Try a city, neighborhood, or address."
    end

    routes, area = run_all([
      -> { hiking.get_trails(lat: place.latitude, lon: place.longitude) },
      -> { transit.area(place.latitude, place.longitude) }
    ])
    trails = routes.value!
    # The area only refines the time zone and label, so searches go ahead without it.
    area = (area.value if area.fulfilled?) || {}
    departure_time = departure_time(place.time_zone || area[:time_zone])

    reachable = trails.zip(trips(place, trails, departure_time, transit)).filter_map do |trail, trip|
      next unless trip

      trail.duration, trail.transfers = trip.values_at(:duration, :transfers)
      trail.origin = place.name
      trail
    end
    Result.new(place: place, area: area[:area], departure_time: departure_time, trails: reachable.sort_by(&:duration))
  end

  def self.trips(place, trails, departure_time, transit)
    transit.trips(origin: place, destinations: trails, departure_time: departure_time)
  rescue SearchErrors::UpstreamError
    # The one-request API is experimental, so fall back to planning each route in turn.
    trails.map { |trail| transit.trip(origin: place, destination: trail, departure_time: departure_time) }
  end

  # Leave now during the day; otherwise at 8 AM, in the origin's time zone.
  def self.departure_time(time_zone, now: Time.current)
    zone = (ActiveSupport::TimeZone[time_zone] if time_zone) || Time.zone
    local = now.in_time_zone(zone)
    if LEAVE_NOW_HOURS.cover?(local.hour)
      # Rounding up to the quarter hour lets searches share cached routes.
      local.change(sec: 0) + ((15 - local.min % 15) % 15).minutes
    else
      day = local.hour < LEAVE_NOW_HOURS.first ? local.to_date : local.to_date.tomorrow
      zone.local(day.year, day.month, day.day, MORNING_HOUR)
    end
  end

  # Runs each block on the shared provider pool and returns the settled futures.
  def self.run_all(blocks)
    pool = Rails.configuration.x.provider_pool
    futures = blocks.map do |block|
      Concurrent::Promises.future_on(pool) { Rails.application.executor.wrap { block.call } }
    end
    # Pool threads may need to load code while this request thread waits.
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { futures.each(&:wait) }
    futures
  end
end
