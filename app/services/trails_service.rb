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
  FIRST_TILES = 4
  # Routes are checked in batches, most promising first, so results show as they are found.
  BATCH_SIZE = 40
  # Hiking at 2 mph with breaks, a hike takes at least MIN_HIKE_HOURS, which
  # leaves time to enjoy short ones, and the whole hike must be done
  # RETURN_MARGIN before the last trip back leaves.
  HIKE_MPH = 2.0
  MIN_HIKE_HOURS = 1.5
  RETURN_MARGIN = 30.minutes
  # Routes whose loose ends are closer than this are hiked as loops.
  LOOP_GAP_METERS = 1_000
  # Routes that transit reaches this close to an end can be hiked from there to
  # the other end. Out and back is simpler, with the same way home, so routes are
  # only hiked one way when out and back would be longer than COMFORTABLE_MILES.
  END_REACH_METERS = 1_500
  COMFORTABLE_MILES = 10
  # Without the one-request API, only this many of the nearest routes are planned one by one.
  MAX_PLANNED_ROUTES = 15
  # Terrain is looked up for up to this many of the most promising routes, a
  # few near each other at a time so they share elevation tiles, and searches
  # wait at most TERRAIN_WAIT_SECONDS for it.
  MAX_TERRAIN_LOOKUPS = 100
  TERRAIN_CHUNK = 6
  TERRAIN_WAIT_SECONDS = 8
  # Routes in cells this many degrees across are near enough to share tiles.
  TERRAIN_CELL_DEGREES = 0.125
  # Routes beyond this many within AREA_METERS of each other rank lower, for variety.
  MAX_PER_AREA = 2
  AREA_METERS = 3_000
  # Scenery counts most toward the recommended order.
  SCENIC_WEIGHT = 0.6
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
    hiking: OverpassService, elevation: ElevationService, &on_found)
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
    enrich(result, search.lookups, elevation)
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
    reached.each { |trail| trail.plan = loop?(trail) ? :loop : :out_and_back }
    return reached if reached.empty?

    # Linear routes can also be hiked to their far end, when transit leaves from there.
    finishes = reached.map { |trail| finish(trail) }
    linear = finishes.each_index.select { |index| finishes[index] }
    ends = linear.map do |index|
      Place.new(name: "#{reached[index].name} finish", latitude: finishes[index][0], longitude: finishes[index][1])
    end
    latest = begin
      transit.latest_returns(origin: place, destinations: reached + ends, deadline: result.return_by,
        earliest_return: result.departure_time + MIN_HIKE_HOURS.hours)
    rescue SearchErrors::UpstreamError
      result.returns_checked = false
      # Routes that couldn't be hiked by the deadline are still left out.
      return reached.select { |trail| trail.arrival + required_hours(trail).hours <= result.return_by }
    end
    from_finish = linear.zip(latest.drop(reached.size)).to_h
    reached.each_with_index.filter_map do |trail, index|
      planned(trail, latest[index], finishes[index], from_finish[index])
    end
  end

  # The trail as it can be hiked and still make the last trip back: back to
  # where it starts, unless that's over COMFORTABLE_MILES out and back or leaves
  # too little time, and transit leaves its far end late enough. nil when
  # neither leaves time to hike it all. How long rides back take is only known
  # once a card's trips are planned, which then prefer quick ones.
  def self.planned(trail, start_return, finish, finish_return)
    trail.plan, trail.finish, trail.last_return = (loop?(trail) ? :loop : :out_and_back), nil, start_return
    back = start_return && time_to_hike?(trail)
    return trail if back && (trail.plan == :loop || hike_miles(trail) <= COMFORTABLE_MILES)

    if finish && finish_return
      through = trail.dup.tap { |candidate| candidate.plan, candidate.finish, candidate.last_return = :through, finish, finish_return }
      return through if time_to_hike?(through)
    end
    trail if back
  end

  def self.time_to_hike?(trail)
    trail.last_return - trail.arrival >= required_hours(trail).hours
  end

  # Whether the route ends where it starts, or near enough to walk back.
  def self.loop?(trail)
    ends = trail.ends
    trail.loop || ends.nil? || OverpassService.distance(*ends.first, *ends.last) < LOOP_GAP_METERS
  end

  # The [latitude, longitude] of a linear route's far end, when transit reaches
  # it near its other end, or nil.
  def self.finish(trail)
    return if loop?(trail)

    near, far = trail.ends.sort_by { |point| OverpassService.distance(trail.latitude, trail.longitude, *point) }
    far if OverpassService.distance(trail.latitude, trail.longitude, *near) <= END_REACH_METERS
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

  # Seconds on transit there and back. Coming back the same way takes about as
  # long as going; each card shows the planned trips once they're looked up.
  def self.round_trip_seconds(trail)
    trail.duration * 2
  end

  # How far the hike goes: once along a loop or to the far end, and twice out and back.
  def self.hike_miles(trail)
    (trail.plan || (trail.loop ? :loop : :out_and_back)) == :out_and_back ? trail.length * 2 : trail.length
  end

  # About how long the whole hike takes.
  def self.hike_hours(trail)
    [hike_miles(trail) / HIKE_MPH, MIN_HIKE_HOURS].max
  end

  # The hike, and the margin before the last trip back.
  def self.required_hours(trail)
    hike_hours(trail) + RETURN_MARGIN / 1.hour.to_f
  end

  # Adds the highlights found in time and the terrain of the most promising
  # routes, then scores and orders every route.
  def self.enrich(result, lookups, elevation)
    settle(lookups.map(&:last), timeout: HIGHLIGHT_WAIT_SECONDS)
    lookups.each do |trails, lookup|
      # Routes are shown without highlights when they cannot be looked up in time.
      found = (lookup.value if lookup.fulfilled?) || {}
      trails.each { |trail| trail.highlights = found[trail.osm_id] || [] }
    end
    add_terrain(result.trails.max_by(MAX_TERRAIN_LOOKUPS) { |trail| score(trail) }, elevation)
    rank(result.trails)
  end

  # How far the routes climb and how far their high points stand above the land
  # around them. Routes whose terrain isn't found in time are ranked without it,
  # and the lookups finish in the background for later searches.
  def self.add_terrain(trails, elevation)
    chunks = trails.sort_by { |trail| trail.midpoint.map { |degrees| (degrees.to_f / TERRAIN_CELL_DEGREES).floor } }
      .each_slice(TERRAIN_CHUNK).to_a
    lookups = settle(chunks.map { |chunk| start { elevation.terrain(chunk) } }, timeout: TERRAIN_WAIT_SECONDS)
    lookups.zip(chunks).each do |lookup, chunk|
      found = (lookup.value if lookup.fulfilled?) || {}
      chunk.each { |trail| trail.terrain = found[trail.osm_id] }
    end
  end

  # Scores the trails, ranking routes after the first MAX_PER_AREA within
  # AREA_METERS of each other lower, and orders them best first.
  def self.rank(trails)
    trails.each { |trail| trail.score = score(trail) }
    ranked = []
    trails.sort_by { |trail| [-trail.score, trail.duration] }.each do |trail|
      nearby = ranked.count { |other| OverpassService.distance(*trail.midpoint, *other.midpoint) < AREA_METERS }
      trail.score -= 1.5 if nearby >= MAX_PER_AREA
      ranked << trail
    end
    trails.each { |trail| trail.score = trail.score.round(2) }
    trails.sort_by! { |trail| [-trail.score, trail.duration] }
  end

  # Higher is better: scenic, unpaved hikes of day-hike length, and not too
  # long a trip there and back.
  def self.score(trail)
    length = case hike_miles(trail)
    when 3..12 then 1.5
    when 2...3, 12..16 then 1
    when 1...2 then 0.25
    else 0
    end
    # Day trips by train often take up to three hours there and back; longer ones count against a hike.
    hours = round_trip_seconds(trail) / 3600.0
    travel = [hours - 3, 0].max * 0.25 + [hours - 6, 0].max * 0.5
    length + scenic(trail) * SCENIC_WEIGHT + (trail.notable ? 0.5 : 0) - trail.paved.to_f * 2.5 -
      (OverpassService.generic_name?(trail.name) ? 1 : 0) - travel - trail.transfers.to_i * 0.1
  end

  # How scenic a route is, from 0 to about 8: the best of its views and
  # waterfalls counts in full, the next one half, and the one after a quarter,
  # so one grand view outweighs many small ones.
  def self.scenic(trail)
    waterfalls = Array(trail.highlights).select { |highlight| highlight[:kind] == "waterfall" }
    features = [views(trail), *waterfalls.map { |highlight| waterfall(highlight) }].sort.reverse
    features.first(3).each_with_index.sum { |value, index| value / 2**index }.round(2)
  end

  # Views, from 0 to about 5.75: a point for every 100 m the route climbs or
  # its high point stands above the land around it, up to four, and more for a
  # mapped viewpoint, a named summit, and a famous summit or viewpoint.
  def self.views(trail)
    terrain = trail.terrain || {}
    highlights = Array(trail.highlights)
    [[terrain[:climb].to_i, terrain[:relief].to_i].max / 100.0, 4].min +
      (highlights.any? { |highlight| highlight[:kind] == "viewpoint" } ? 0.5 : 0) +
      (highlights.any? { |highlight| highlight[:kind] == "peak" && highlight[:name] } ? 0.25 : 0) +
      (highlights.any? { |highlight| highlight[:kind] != "waterfall" && highlight[:notable] } ? 1 : 0)
  end

  # A waterfall, from 1.5 to 4.5: more for a name, a Wikipedia article, and every 20 m of height, up to 1.5.
  def self.waterfall(highlight)
    1.5 + (highlight[:name] ? 0.5 : 0) + (highlight[:notable] ? 1 : 0) + [highlight[:height].to_f / 20, 1.5].min
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
