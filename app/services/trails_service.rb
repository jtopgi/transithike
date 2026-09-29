# Weekend day hikes by train from the city, with a train back the same evening.
module TrailsService
  # return_by is when everyone should be back at the origin, returns_checked is
  # false when the way back could not be looked up, and complete is false when
  # some routes could not be checked.
  Result = Struct.new(:place, :area, :departure_time, :return_by, :trails, :returns_checked, :complete,
    keyword_init: true)
  # Day trips are on Saturday or Sunday, whichever comes first unless one is
  # chosen, and set out at 8 AM, or now once the day has begun. From 10 AM on,
  # it's too late to set out that day, so the trip is a week later.
  WEEKEND_DAYS = { "saturday" => 6, "sunday" => 0 }.freeze
  MORNING_HOUR = 8
  LATEST_START_HOUR = 10
  RETURN_BY_HOUR = 23
  # Stations closer than this are in or next to the city, so hikes near them aren't day trips.
  MIN_DISTANCE_METERS = 20_000
  # Routes in the tiles with the quickest stations are checked first, while the rest are found.
  FIRST_TILES = OverpassService::TILES_PER_QUERY
  # Routes are checked in batches, most promising first, so results show as they are found.
  BATCH_SIZE = 40
  # Hiking at 2 mph with breaks. Routes that don't loop are hiked out and back,
  # and at least REQUIRED_HOURS must be left before the last trip back; longer
  # routes can be shortened.
  HIKE_MPH = 2.0
  HIKE_HOURS = 1.5..7
  REQUIRED_HOURS = 1.5..4
  # Without the one-request API, only this many of the nearest routes are planned one by one.
  MAX_PLANNED_ROUTES = 15
  # Popularity is looked up for the most promising routes.
  MAX_AREA_LOOKUPS = 40
  # Routes beyond this many in one park or natural area rank lower, for variety.
  MAX_PER_AREA = 2
  # Points toward the scenic score for each highlight on the way.
  SCENIC_POINTS = { "waterfall" => 2, "peak" => 2, "viewpoint" => 1 }.freeze
  # Highlights only refine the ranking, so searches wait at most this long for
  # them once every batch is checked. Slower lookups finish in the background
  # and are cached for later searches.
  HIGHLIGHT_WAIT_SECONDS = 5
  # Searches give up on the first tiles' routes after this long, waiting for a query slot included.
  OVERPASS_WAIT_SECONDS = 90

  # origin is text to look up, near a rough [latitude, longitude] if given, or
  # a Place chosen from suggestions or the device's location; day is a
  # WEEKEND_DAYS key. The block, if any, is called as the search goes: with
  # :place and the result once the departure time is known, with :checking and
  # how many routes a batch checks, with :trails and each batch's routes that
  # have a trip there and back, with :ranking and how many routes were found
  # once every batch is checked, and with :update and every route once
  # highlights and popularity rank them. Returns the result.
  def self.search(origin:, day: nil, near: nil, places: PhotonService, transit: TransitousService,
    hiking: OverpassService, wiki: WikipediaService, &on_found)
    place = origin.is_a?(String) ? places.geocode(origin, near: near) : origin
    unless place
      raise SearchErrors::InvalidInput, "We could not find that starting point. Try a city, neighborhood, or address."
    end

    lat, lon = place.latitude, place.longitude
    # The area only refines the search, which goes ahead without it.
    area = optional { transit.area(lat, lon) } || {}
    departure_time = departure_time(place.time_zone || area[:time_zone], day: day)
    result = Result.new(place: place, area: area[:area], departure_time: departure_time,
      return_by: departure_time.change(hour: RETURN_BY_HOUR), trails: [], returns_checked: true, complete: true)
    on_found&.call(:place, result)

    stations = transit.rail_stations(origin: place, departure_time: departure_time).select do |station|
      OverpassService.distance(lat, lon, station[0], station[1]) >= MIN_DISTANCE_METERS
    end
    return result if stations.empty?

    access = TransitAccess.new(lat, lon, stations)
    tiles = hiking.tiles(stations)
    nearby = start(overpass_pool) { hiking.routes_in(tiles.first(FIRST_TILES)) }
    # Routes in the other tiles only add to the search, so it goes ahead without them.
    farther = start(overpass_pool) { hiking.routes_in(tiles.drop(FIRST_TILES)) } if tiles.size > FIRST_TILES
    search = Search.new(place, access, result, transit, hiking, on_found)
    routes = finished(nearby).value!
    search.check(hiking.pick(routes, access: access).first(BATCH_SIZE))
    routes = (routes + optional { finished(farther).value }.to_a).uniq { |route| route[:id] } if farther
    search.check(hiking.pick(routes, access: access))
    raise search.error if result.trails.empty? && search.error
    return result if result.trails.empty?

    on_found&.call(:ranking, result.trails.size)
    enrich(result, search.lookups, wiki)
    on_found&.call(:update, result.trails)
    result
  end

  # Checks routes in batches, up to OverpassService::MAX_TRANSIT_ROUTES per search.
  class Search
    attr_reader :lookups, :error

    def initialize(place, access, result, transit, hiking, on_found)
      @place, @access, @result, @transit, @hiking, @on_found = place, access, result, transit, hiking, on_found
      @checked, @lookups, @budget = Set.new, [], { planned: MAX_PLANNED_ROUTES }
    end

    def check(ids)
      ids = ids.reject { |id| @checked.include?(id) }.first(OverpassService::MAX_TRANSIT_ROUTES - @checked.size)
      ids.each_slice(BATCH_SIZE) { |batch| check_batch(batch) }
    end

    private

    # A failed batch is skipped, so the routes already found are still shown.
    def check_batch(ids)
      @checked.merge(ids)
      @on_found&.call(:checking, ids.size)
      trails = @hiking.trails_for(ids, lat: @place.latitude, lon: @place.longitude, access: @access)
      found = TrailsService.round_trips(@place, trails, @result, @transit, @budget)
      return if found.empty?

      found.each { |trail| trail.score = TrailsService.score(trail).round(2) }
      @lookups << [found, TrailsService.start(TrailsService.overpass_pool) { @hiking.highlights(found) }]
      @result.trails.concat(found)
      @on_found&.call(:trails, found)
    rescue SearchErrors::UpstreamError => error
      @error ||= error
      @result.complete = false
    end
  end

  def self.optional
    yield
  rescue StandardError
    nil
  end

  # The trails a train reaches, and the subway doesn't, with a way back to the
  # origin the same day that leaves time to hike them. When the way back can't
  # be looked up, every trail reached is kept and the result says so.
  def self.round_trips(place, trails, result, transit, budget)
    reached = trails.zip(trips(place, trails, result.departure_time, transit, budget)).filter_map do |trail, trip|
      next unless trip

      trail.duration, trail.transfers = trip.values_at(:duration, :transfers)
      trail.arrival = result.departure_time + trail.duration
      trail.origin = place.name
      trail
    end
    reached = beyond_city_transit(place, reached, result.departure_time, transit)
    return reached if reached.empty?

    latest = begin
      transit.latest_returns(origin: place, destinations: reached, deadline: result.return_by,
        earliest_return: result.departure_time + REQUIRED_HOURS.first.hours)
    rescue SearchErrors::UpstreamError
      result.returns_checked = false
      return reached
    end
    reached.zip(latest).filter_map do |trail, time|
      trail.last_return = time
      trail if time && time - trail.arrival >= required_hours(trail).hours
    end
  end

  # City dwellers already know the hikes the subway or light rail reaches, so
  # those are left out. When that can't be checked, every trail is kept.
  def self.beyond_city_transit(place, trails, departure_time, transit)
    return trails if trails.empty?

    city = transit.trips(origin: place, destinations: trails, departure_time: departure_time,
      modes: TransitousService::CITY_MODES)
    trails.zip(city).filter_map { |trail, trip| trail unless trip }
  rescue SearchErrors::UpstreamError
    trails
  end

  def self.trips(place, trails, departure_time, transit, budget)
    transit.trips(origin: place, destinations: trails, departure_time: departure_time)
  rescue SearchErrors::UpstreamError
    # The one-request API is experimental, so fall back to planning the nearest routes in turn.
    nearest = trails.each_index.min_by([budget[:planned], 0].max) { |index| trails[index].distance }.to_set
    budget[:planned] -= nearest.size
    trails.each_with_index.map do |trail, index|
      transit.trip(origin: place, destination: trail, departure_time: departure_time) if nearest.include?(index)
    end
  end

  # About how long hiking the whole route takes.
  def self.hike_hours(trail)
    ((trail.loop ? trail.length : trail.length * 2) / HIKE_MPH).clamp(HIKE_HOURS)
  end

  def self.required_hours(trail)
    hike_hours(trail).clamp(REQUIRED_HOURS)
  end

  # Adds the highlights found in time and the popularity of the most promising
  # routes' areas, then scores and orders every route.
  def self.enrich(result, lookups, wiki)
    settle(lookups.map(&:last), timeout: HIGHLIGHT_WAIT_SECONDS)
    lookups.each do |trails, lookup|
      # Routes are shown without highlights when they cannot be looked up in time.
      found = (lookup.value if lookup.fulfilled?) || {}
      trails.each { |trail| trail.highlights = found[trail.osm_id] || [] }
    end
    add_areas(result.trails.max_by(MAX_AREA_LOOKUPS) { |trail| score(trail) }, wiki)
    rank(result.trails)
  end

  # The nearest park or natural area with a Wikipedia article, whose page views
  # show how well known it is. Routes whose lookup fails are shown without one.
  def self.add_areas(trails, wiki)
    run_all(trails.map { |trail| -> { wiki.nearby_area(*trail.midpoint) } }).zip(trails)
      .each { |lookup, trail| trail.area = (lookup.value if lookup.fulfilled?)&.slice(:title, :article_url, :monthly_views) }
  end

  # Scores the trails, ranking routes after the first MAX_PER_AREA in one area lower, and orders them best first.
  def self.rank(trails)
    trails.each { |trail| trail.score = score(trail) }
    trails.select { |trail| trail.area&.dig(:title) }.group_by { |trail| trail.area[:title] }.each_value do |group|
      group.sort_by { |trail| [-trail.score, trail.duration] }.drop(MAX_PER_AREA).each { |trail| trail.score -= 1.5 }
    end
    trails.each { |trail| trail.score = trail.score.round(2) }
    trails.sort_by! { |trail| [-trail.score, trail.duration] }
  end

  # Higher is better: unpaved routes of day-hike length, with highlights on the
  # way, in well-known areas, with time to enjoy them, and not too far to go.
  def self.score(trail)
    length = case trail.length
    when 3..12 then 1.5
    when 2...3, 12..16 then 1
    when 1...2 then 0.25
    else 0
    end
    views = trail.area&.dig(:monthly_views).to_i
    popularity = [Math.log10(views + 1) - 2, 0].max * 0.75
    # Day trips by train often take an hour or two each way; longer ones count against a hike.
    hours = trail.duration / 3600.0
    travel = [hours - 1.5, 0].max * 0.5 + [hours - 3, 0].max
    rushed = trail.last_return && trail.last_return - trail.arrival < hike_hours(trail).hours ? 0.5 : 0
    length + [scenic(trail), 4].min * 0.5 + popularity + (trail.notable ? 0.5 : 0) - trail.paved.to_f * 2.5 -
      (OverpassService.generic_name?(trail.name) ? 1 : 0) - travel - trail.transfers.to_i * 0.1 - rushed
  end

  # Waterfalls and summits count double viewpoints, and unnamed ones half as much as named ones.
  def self.scenic(trail)
    Array(trail.highlights).sum do |highlight|
      SCENIC_POINTS.fetch(highlight[:kind], 0) * (highlight[:name] ? 1 : 0.5)
    end
  end

  # 8 AM on the day of the trip in the origin's time zone, or now, rounded up to
  # the quarter hour, once that morning has begun.
  def self.departure_time(time_zone, day: nil, now: Time.current)
    zone = (ActiveSupport::TimeZone[time_zone] if time_zone) || Time.zone
    local = now.in_time_zone(zone)
    date = trip_date(local, day)
    start = zone.local(date.year, date.month, date.day, MORNING_HOUR)
    return start unless local > start

    # Rounding lets searches share cached trips.
    local.change(sec: 0) + ((15 - local.min % 15) % 15).minutes
  end

  # The date of the next Saturday or Sunday, or of the day given, that isn't too late to set out.
  def self.trip_date(local, day = nil)
    WEEKEND_DAYS.values_at(*(day ? [day] : WEEKEND_DAYS.keys)).map do |weekday|
      date = local.to_date + (weekday - local.wday) % 7
      date == local.to_date && local.hour >= LATEST_START_HOUR ? date + 7 : date
    end.min
  end

  # Runs each block on the shared provider pool and returns the settled futures.
  def self.run_all(blocks)
    settle(blocks.map { |block| start(&block) })
  end

  # A future for the block, run on the shared provider pool unless another is given.
  def self.start(pool = Rails.configuration.x.provider_pool, &block)
    Concurrent::Promises.future_on(pool) { Rails.application.executor.wrap(&block) }
  end

  def self.overpass_pool
    Rails.configuration.x.overpass_pool
  end

  # The hiking-route lookup's future once it has finished, or raises when the provider is too busy.
  def self.finished(future)
    settle([future], timeout: OVERPASS_WAIT_SECONDS)
    raise SearchErrors::ProviderBusy, OverpassService::BUSY unless future.resolved?

    future
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
