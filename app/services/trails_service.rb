module TrailsService
  Result = Struct.new(:place, :area, :departure_time, :trails, keyword_init: true)
  # Hikers usually set out in the morning, so late searches plan for the next one.
  LEAVE_NOW_HOURS = 5..14
  MORNING_HOUR = 8
  MAX_RESULTS = 30
  # Further routes in one park or natural area follow the others, for variety.
  MAX_PER_AREA = 2
  # Without the one-request API, only the nearest routes are planned one by one.
  MAX_PLANNED_ROUTES = 15
  # Points toward the scenic score for each highlight on the way.
  SCENIC_POINTS = { "waterfall" => 2, "peak" => 2, "viewpoint" => 1 }.freeze
  # Highlights only refine the ranking, so searches wait at most this long for
  # them once trips are planned. Slower lookups finish in the background and
  # are cached for later searches.
  HIGHLIGHT_WAIT_SECONDS = 5

  # origin is text to look up, or a Place chosen from suggestions or the device's location.
  def self.search(origin:, places: PhotonService, transit: TransitousService, hiking: OverpassService,
    wiki: WikipediaService)
    place = origin.is_a?(String) ? places.geocode(origin) : origin
    unless place
      raise SearchErrors::InvalidInput, "We could not find that starting point. Try a city, neighborhood, or address."
    end

    candidates, plan = run_all([
      -> { hiking.candidates(lat: place.latitude, lon: place.longitude) },
      -> { plan(place, transit) }
    ])
    area, departure_time, stops = plan.value!
    access = TransitAccess.new(place.latitude, place.longitude, stops) if stops
    trails = hiking.trails(candidates.value!, lat: place.latitude, lon: place.longitude, access: access)

    highlights = start { hiking.highlights(trails) }
    trips = settle([start { trips(place, trails, departure_time, transit) }]).first.value!
    settle([highlights], timeout: HIGHLIGHT_WAIT_SECONDS)
    # Routes are shown without highlights when they cannot be looked up in time.
    highlights = (highlights.value if highlights.fulfilled?) || {}
    reachable = trails.zip(trips).filter_map do |trail, trip|
      next unless trip

      trail.duration, trail.transfers = trip.values_at(:duration, :transfers)
      trail.highlights = highlights[trail.osm_id] || []
      trail.origin = place.name
      trail
    end
    # The most promising routes are shown, and ranked again once their areas' popularity is known.
    shown = reachable.sort_by { |trail| [-score(trail), trail.duration] }.first(MAX_RESULTS)
    add_areas(shown, wiki)
    shown.each { |trail| trail.score = score(trail).round(2) }
    Result.new(place: place, area: area[:area], departure_time: departure_time,
      trails: varied(shown.sort_by { |trail| [-trail.score, trail.duration] }))
  end

  def self.varied(trails)
    counts = Hash.new(0)
    first, rest = trails.partition do |trail|
      title = trail.area&.dig(:title)
      title.nil? || (counts[title] += 1) <= MAX_PER_AREA
    end
    first + rest
  end

  # The origin's area, the departure time in its time zone, and the transit stops
  # reachable from it. The area and stops only refine the search, which goes ahead without them.
  def self.plan(place, transit)
    area = optional { transit.area(place.latitude, place.longitude) } || {}
    departure_time = departure_time(place.time_zone || area[:time_zone])
    [area, departure_time, optional { transit.reachable_stops(origin: place, departure_time: departure_time) }]
  end

  def self.optional
    yield
  rescue StandardError
    nil
  end

  def self.trips(place, trails, departure_time, transit)
    transit.trips(origin: place, destinations: trails, departure_time: departure_time)
  rescue SearchErrors::UpstreamError
    # The one-request API is experimental, so fall back to planning the nearest routes in turn.
    nearest = trails.each_index.min_by(MAX_PLANNED_ROUTES) { |index| trails[index].distance }.to_set
    trails.each_with_index.map do |trail, index|
      transit.trip(origin: place, destination: trail, departure_time: departure_time) if nearest.include?(index)
    end
  end

  # The nearest park or natural area with a Wikipedia article, whose page views
  # show how well known it is. Routes whose lookup fails are shown without one.
  def self.add_areas(trails, wiki)
    run_all(trails.map { |trail| -> { wiki.nearby_area(*trail.midpoint) } }).zip(trails)
      .each { |lookup, trail| trail.area = (lookup.value if lookup.fulfilled?)&.slice(:title, :article_url, :monthly_views) }
  end

  # Higher is better: unpaved routes of day-hike length, with highlights on the
  # way, in well-known areas, that are quick to reach.
  def self.score(trail)
    length = if trail.length.between?(1.5, 12) then 1 elsif trail.length >= 1 then 0.5 else 0 end
    views = trail.area&.dig(:monthly_views).to_i
    popularity = [Math.log10(views + 1) - 2, 0].max * 0.75
    hours = trail.duration / 3600.0
    travel = [hours - 0.75, 0].max * 0.75 + [hours - 2, 0].max
    length + [scenic(trail), 4].min * 0.5 + popularity + (trail.notable ? 0.5 : 0) - trail.paved.to_f * 2.5 -
      (OverpassService.generic_name?(trail.name) ? 1 : 0) - travel - trail.transfers.to_i * 0.2
  end

  # Waterfalls and summits count double viewpoints, and unnamed ones half as much as named ones.
  def self.scenic(trail)
    Array(trail.highlights).sum do |highlight|
      SCENIC_POINTS.fetch(highlight[:kind], 0) * (highlight[:name] ? 1 : 0.5)
    end
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
    settle(blocks.map { |block| start(&block) })
  end

  # A future for the block, run on the shared provider pool.
  def self.start(&block)
    Concurrent::Promises.future_on(Rails.configuration.x.provider_pool) do
      Rails.application.executor.wrap(&block)
    end
  end

  # Waits for the futures, or until timeout seconds have passed, and returns them.
  def self.settle(futures, timeout: nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
    # Pool threads may need to load code while this request thread waits.
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      futures.each { |future| future.wait(deadline && [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max) }
    end
    futures
  end
end
