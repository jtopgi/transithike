# Weekend day hikes by train from the city's major stations, with a train back the same evening.
module TrailsService
  # stations are the stations trips leave from, return_by is when everyone
  # should be back there, returns_checked is false when the way back could
  # not be looked up, and complete is false when some routes could not be checked.
  Result = Struct.new(:place, :area, :stations, :departure_time, :return_by, :trails, :returns_checked, :complete,
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
  # leaves time to enjoy short ones, and the whole hike must be done by sunset
  # and RETURN_MARGIN before the last trip back leaves. Twilight after sunset
  # leaves light to walk from the trail to the station.
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
  # Quiet surroundings, away from road, rail, and air traffic, count up to as
  # much as a good view, about 200 m up, where the noise map shows them.
  QUIET_SCENIC = 2.0
  # Searches wait at most this long for the noise along a batch's routes, which
  # are kept without it otherwise.
  NOISE_WAIT_SECONDS = 8
  # Highlights only refine the ranking, so searches visitors wait on wait at
  # most HIGHLIGHT_WAIT_SECONDS for them once every batch is checked, and those
  # in the background, as guide builds' are, longer, so they have them. Slower
  # lookups finish in the background and are cached for later searches.
  HIGHLIGHT_WAIT_SECONDS = 5
  BACKGROUND_HIGHLIGHT_WAIT_SECONDS = 60
  # Searches give up on the first tiles' routes after this long, waiting for a query slot included.
  OVERPASS_WAIT_SECONDS = 90
  # Routes are picked with how far the land rises around them, looked up for
  # cells this many degrees across at once, waiting at most this long.
  RELIEF_CELL_DEGREES = 1.0
  RELIEF_WAIT_SECONDS = 8
  # Hikes reached from more than one station are shown from the one that gets
  # there soonest, counting the trip across the city to the station at about
  # this speed.
  CITY_METERS_PER_MINUTE = 250.0
  # Searches check on their stations' searches this often, and say they're
  # still going when nothing has changed for KEEP_ALIVE_SECONDS.
  FOLLOW_SECONDS = 0.25
  KEEP_ALIVE_SECONDS = 15
  # A search gives up on all the hikes whose trips aren't planned yet when no
  # hike's trips anywhere have been planned for this long, as when the pool is
  # stuck, which code reloading in development can do.
  TRIP_QUIET_SECONDS = 60

  # origin is text to look up, near a rough [latitude, longitude] if given, or
  # a Place chosen from suggestions or the device's location; day is a
  # WEEKEND_DAYS key. Trips leave from the major stations near it, and
  # getting to them is up to the visitor. The block, if any, is called as the
  # search goes: with :place and the result once its stations and departure
  # time are known, with :checking, how many routes a batch checks, and the
  # station it checks from, with :trails and the routes found to have a trip
  # there and back, or to have a quicker one than those already found, with
  # :update and the routes found once highlights and terrain rank them, and
  # with :waiting while nothing changes for a while. Each route is found from
  # the station that gets there soonest. Stations' searches are kept and
  # shared (see StationSearch); with fresh, only recent complete ones are used.
  # Returns the result, with every route found, best first.
  def self.search(origin:, day: nil, near: nil, fresh: false, places: PhotonService, transit: TransitousService,
    hiking: OverpassService, elevation: ElevationService, noise: NoiseService, &on_found)
    place = origin.is_a?(String) ? places.geocode(origin, near: near) : origin
    unless place
      raise SearchErrors::InvalidInput, "We could not find that starting point. Try a city, neighborhood, or address."
    end

    # The area only refines the search, which goes ahead without it.
    area = optional { transit.area(place.latitude, place.longitude) } || {}
    departure_time = departure_time(place.time_zone || area[:time_zone], day: day)
    stations = transit.major_stations(origin: place, departure_time: departure_time)
    result = Result.new(place: place, area: area[:area], stations: stations, departure_time: departure_time,
      return_by: departure_time.change(hour: RETURN_BY_HOUR), trails: [], returns_checked: true, complete: true)
    on_found&.call(:place, result)
    return result if stations.empty?

    searches = stations.map do |station|
      StationSearch.start(station, departure_time, fresh: fresh, transit: transit, hiking: hiking, elevation: elevation,
        noise: noise)
    end
    follow(searches, result, &on_found)
  end

  # Follows the stations' searches as they go, passing on what changes, and
  # returns the result once they're all done.
  def self.follow(searches, result, &on_found)
    merged = Merged.new(result, on_found)
    seen = Array.new(searches.size, 0)
    quiet_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      done, progressed = true, false
      searches.each_with_index do |search, index|
        events, finished = search.events_since(seen[index])
        seen[index] += events.size
        done &&= finished
        progressed ||= events.any?
        events.each { |event, payload| merged.take(event, payload) }
      end
      break if done

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      quiet_since = now if progressed
      next if progressed

      if now - quiet_since >= KEEP_ALIVE_SECONDS
        on_found&.call(:waiting, nil)
        quiet_since = now
      end
      # The stations' searches may need to load code while this one waits.
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { sleep FOLLOW_SECONDS }
    end
    merged.result
  end

  # A search's routes as its stations' searches find them, each from the
  # station that gets there soonest.
  class Merged
    def initialize(result, on_found)
      @result, @on_found, @shown, @errors = result, on_found, {}, []
    end

    # Takes in a station search's event, passing on what changes what's shown.
    def take(event, payload)
      case event
      when :checking then @on_found&.call(:checking, payload)
      when :trails
        show(:trails, payload.select { |trail| @shown[trail.osm_id].nil? || TrailsService.sooner?(trail, @shown[trail.osm_id], @result.place) })
      when :update then show(:update, payload.select { |trail| @shown[trail.osm_id]&.station == trail.station })
      when :done
        @result.returns_checked &&= payload.returns_checked
        @result.complete &&= payload.complete
      when :failed
        @errors << payload
        @result.complete = false
      end
    end

    # The result with every route shown, best first. Raises when none were
    # found and some station's search failed.
    def result
      raise @errors.first if @shown.empty? && @errors.any?

      @result.trails = @shown.values.sort_by { |trail| [-trail.score.to_f, trail.duration] }
      @result
    end

    private

    def show(event, trails)
      return if trails.empty?

      trails.each { |trail| @shown[trail.osm_id] = trail }
      @on_found&.call(event, trails)
    end
  end

  # Whether a route found from one station is reached sooner than from
  # another, counting the trip across the city from the place to each station.
  def self.sooner?(trail, other, place)
    reach_seconds(trail, place) < reach_seconds(other, place)
  end

  def self.reach_seconds(trail, place)
    station = trail.station
    meters = station ? OverpassService.distance(place.latitude, place.longitude, station.latitude, station.longitude) : 0
    trail.duration + meters / CITY_METERS_PER_MINUTE * 60
  end

  # Hikes by train from a station that leave at departure_time, with a train
  # back to it by RETURN_BY_HOUR. The block, if any, is called as the search
  # goes: with :checking, how many routes a batch checks, and the station,
  # with :trails and each batch's routes that have a trip there and back, and
  # with :update and every route once highlights and terrain rank them, each
  # time with copies, so the search can go on. Returns the station's result.
  def self.from_station(station, departure_time, transit: TransitousService, hiking: OverpassService,
    elevation: ElevationService, noise: NoiseService, &on_found)
    place = station.place(departure_time.time_zone.tzinfo.name)
    result = Result.new(place: place, stations: [station], departure_time: departure_time,
      return_by: departure_time.change(hour: RETURN_BY_HOUR), trails: [], returns_checked: true, complete: true)
    stations = transit.rail_stations(origin: station, departure_time: departure_time).select do |stop|
      OverpassService.distance(station.latitude, station.longitude, stop[0], stop[1]) >= MIN_DISTANCE_METERS
    end
    return result if stations.empty?

    access = TransitAccess.new(station.latitude, station.longitude, stations)
    tiles = hiking.tiles(stations)
    # Tiles whose routes don't load leave their scenery unchecked, and the search incomplete.
    failures = Concurrent::Array.new
    nearby = start(overpass_pool) { hiking.routes_in(tiles.first(FIRST_TILES), failures: failures) }
    # Routes in the other tiles only add to the search, so it goes ahead without them.
    farther = start(overpass_pool) { hiking.routes_in(tiles.drop(FIRST_TILES), failures: failures) } if tiles.size > FIRST_TILES
    noise = noise_at(station, noise)
    search = Search.new(station, place, access, result, transit, hiking, elevation, noise, on_found)
    routes = finished(nearby).value!
    relief = reliefs(routes, elevation)
    search.check(hiking.pick(routes, access: access, relief: relief).first(BATCH_SIZE))
    if farther
      more = optional { finished(farther).value! }
      result.complete = false unless more
      more = Array(more).reject { |route| relief.key?(route[:id]) }
      relief = relief.merge(reliefs(more, elevation))
      routes = (routes + more).uniq { |route| route[:id] }
    end
    search.check(hiking.pick(routes, access: access, relief: relief))
    result.complete = false if failures.any?
    raise search.error if result.trails.empty? && search.error
    return result if result.trails.empty?

    enrich(result, search.lookups, elevation)
    on_found&.call(:update, result.trails.map(&:dup))
    result
  end

  # Checks routes in batches, up to OverpassService::MAX_TRANSIT_ROUTES per search.
  class Search
    attr_reader :lookups, :error

    def initialize(station, place, access, result, transit, hiking, elevation, noise, on_found)
      @station, @place, @access, @result, @transit, @hiking, @on_found = station, place, access, result, transit, hiking, on_found
      @elevation, @noise = elevation, noise
      @checked, @lookups, @budget = Set.new, [], { planned: MAX_PLANNED_ROUTES }
      # Once planning trips is stuck, the search plans no more.
      @stuck = Concurrent::AtomicBoolean.new
    end

    def check(ids)
      ids = ids.reject { |id| @checked.include?(id) }.first(OverpassService::MAX_TRANSIT_ROUTES - @checked.size)
      ids.each_slice(BATCH_SIZE) { |batch| check_batch(batch) }
    end

    private

    # A batch whose routes can't be looked up is skipped, so the routes already found are still shown.
    def check_batch(ids)
      @checked.merge(ids)
      @on_found&.call(:checking, [ids.size, @station])
      trails = routes(ids)
      # The noise along the routes, and their terrain, are looked up while transit is checked.
      noise = TrailsService.noise_lookups(trails, @noise) if @noise
      terrain = TrailsService.terrain_lookups(trails, @elevation)
      found = TrailsService.round_trips(@place, trails, @result, @transit, @budget)
      found = TrailsService.away_from_traffic(found, noise) if noise
      # Knowing their terrain, hikes show with their climb, ranked by their views.
      kept = plan(TrailsService.with_terrain(found, terrain))
      @lookups << [kept, TrailsService.start(TrailsService.overpass_pool) { @hiking.highlights(kept) }] if kept.any?
    rescue SearchErrors::UpstreamError => error
      fail_with(error)
    end

    # Plans the trails' trips, showing each hike as soon as they're planned, and returns those kept.
    def plan(trails)
      return [] if trails.empty?

      TrailsService.frequent(trails, @place, @result, @transit, failed: method(:fail_with), stuck: @stuck) do |trail|
        trail.station = @station
        trail.score = TrailsService.score(trail).round(2)
        @result.trails << trail
        @on_found&.call(:trails, [trail.dup])
      end
    end

    # The routes with the ids, or, when none can be looked up at once, as
    # when Overpass is busy, each half of them after a pause, leaving out a
    # half that still can't be.
    def routes(ids)
      trails(ids)
    rescue SearchErrors::UpstreamError => error
      raise error if ids.size < 2

      sleep Rails.configuration.x.overpass_retry_pause_seconds
      ids.each_slice((ids.size / 2.0).ceil).flat_map do |half|
        trails(half)
      rescue SearchErrors::UpstreamError => failure
        fail_with(failure)
        []
      end
    end

    # The routes with the ids that can be looked up, as those stored are
    # where Overpass can't be reached; the search is incomplete without the rest.
    def trails(ids)
      failures = []
      found = @hiking.trails_for(ids, lat: @place.latitude, lon: @place.longitude, access: @access, failures: failures)
      fail_with(failures.first) if failures.any?
      found
    end

    def fail_with(error)
      @error ||= error
      @result.complete = false
    end
  end

  def self.optional
    yield
  rescue StandardError
    nil
  end

  # The trails with at least TripPlans::MIN_TRIPS trips there that arrive in
  # time to hike them and as many back before dark, most promising first, each
  # yielded as soon as its trips are planned, with when the first trip there
  # arrives and the last trip back leaves. Trails whose trips can't be planned
  # are left out, the result says some hikes couldn't be checked, and failed is
  # called with the error. When no hike's trips anywhere have been planned for
  # TRIP_QUIET_SECONDS, planning is stuck: the hikes planned by then are kept,
  # the rest are given up on at once, and stuck says so for later batches.
  def self.frequent(trails, place, result, transit, failed: nil, stuck: Concurrent::AtomicBoolean.new)
    plans = trails.map do |trail|
      start(trip_pool) do
        # Hikes given up on before their turn aren't planned.
        next if stuck.true?

        TripPlans.frequent(trail, origin: place, leave: result.departure_time, back_by: result.return_by, transit: transit)
      ensure
        Rails.configuration.x.trips_planned.increment
      end
    end
    counter = Rails.configuration.x.trips_planned
    count, quiet_since = counter.value, Process.clock_gettime(Process::CLOCK_MONOTONIC)
    kept = trails.zip(plans).filter_map do |trail, plan|
      until plan.resolved? || stuck.true?
        settle([plan], timeout: 1)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if counter.value != count
          count, quiet_since = counter.value, now
        elsif now - quiet_since >= TRIP_QUIET_SECONDS
          stuck.make_true
        end
      end
      # A resolved plan stays as it is, so it's looked at once.
      done = plan if plan.resolved?
      unless done&.fulfilled?
        reason = done ? done.reason : SearchErrors::ProviderBusy.new(SearchHttp::BUSY_MESSAGE)
        raise reason unless reason.is_a?(SearchErrors::UpstreamError)

        result.complete = false
        failed&.call(reason)
        next
      end
      next unless (trips = done.value)

      trail.arrival = Time.iso8601(trips[:there][:arrival])
      trail.last_return = Time.iso8601(trips[:ways][:last][:departure])
      yield trail if block_given?
      trail
    end
    # Hikes skipped once planning was stuck weren't checked either.
    result.complete = false if stuck.true?
    kept
  end

  # Searches no visitor waits on plan trips on a pool of their own.
  def self.trip_pool
    config = Rails.configuration.x
    ProviderSlots.priority == ProviderSlots::BACKGROUND ? config.background_trip_pool : config.trip_pool
  end

  # The trails a train reaches, and the subway doesn't, with a way back to the
  # origin the same day that leaves time to hike them. When the way back can't
  # be looked up, every trail reached is kept and the result says so.
  def self.round_trips(place, trails, result, transit, budget)
    reached = trails.zip(trips(place, trails, result.departure_time, transit, budget)).filter_map do |trail, trip|
      next unless trip

      trail.duration, trail.transfers = trip.values_at(:duration, :transfers)
      trail.arrival = result.departure_time + trail.duration
      trail.sunset = Daylight.sunset(result.departure_time, trail.latitude, trail.longitude)
      trail.origin = place.name
      # Routes there isn't the daylight to hike even one way are left out.
      trail if daylight?(trail, [trail.length / HIKE_MPH, MIN_HIKE_HOURS].max)
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
      # Routes that couldn't be hiked by the deadline, or by sunset, are still left out.
      return reached.select { |trail| trail.arrival + required_hours(trail).hours <= result.return_by && daylight?(trail) }
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
    trail.last_return - trail.arrival >= required_hours(trail).hours && daylight?(trail)
  end

  # Whether a hike of hours from when transit arrives is done by sunset, or
  # there's no sunset that day.
  def self.daylight?(trail, hours = hike_hours(trail))
    trail.sunset.nil? || trail.arrival + hours.hours <= trail.sunset
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
  # routes still without it, then scores and orders every route.
  def self.enrich(result, lookups, elevation)
    background = ProviderSlots.priority == ProviderSlots::BACKGROUND
    settle(lookups.map(&:last), timeout: background ? BACKGROUND_HIGHLIGHT_WAIT_SECONDS : HIGHLIGHT_WAIT_SECONDS)
    lookups.each do |trails, lookup|
      # Routes are shown without highlights when they cannot be looked up in time.
      found = (lookup.value if lookup.fulfilled?) || {}
      trails.each { |trail| trail.highlights = found[trail.osm_id] || [] }
    end
    add_terrain(result.trails.reject(&:terrain).max_by(MAX_TERRAIN_LOOKUPS) { |trail| score(trail) }, elevation)
    rank(result.trails)
  end

  # How far the land rises around each route, as { id => meters }, looked up a
  # cell's routes at a time, all at once. Routes whose relief isn't found in
  # time are picked without it, and the lookups finish in the background,
  # leaving their tiles for later searches.
  def self.reliefs(routes, elevation)
    cells = routes.group_by { |route| route.values_at(:latitude, :longitude).map { |degrees| (degrees.to_f / RELIEF_CELL_DEGREES).floor } }
    settle(cells.values.map { |cell| start { elevation.reliefs(cell) } }, timeout: RELIEF_WAIT_SECONDS)
      .select(&:fulfilled?).map(&:value).reduce({}, :merge)
  end

  # The noise provider for searches from the station, where the noise map
  # covers the station's time zone, so that it's the same whoever searches, or
  # else nil.
  def self.noise_at(station, noise)
    noise if NoiseService.covers?(station.time_zone)
  end

  # Lookups of the noise along the routes, near ones together so they share
  # tiles, as [routes, future] pairs.
  def self.noise_lookups(trails, noise)
    trails.group_by { |trail| trail.midpoint.map { |degrees| (degrees.to_f / TERRAIN_CELL_DEGREES).floor } }.values
      .map { |cell| [cell, start { noise.noise(cell) }] }
  end

  # The trails that aren't mostly beside loud traffic, with the noise along
  # them, waiting at most NOISE_WAIT_SECONDS for it. Trails whose noise isn't
  # found in time are kept with what was known of it, and the lookups finish
  # in the background for later searches.
  def self.away_from_traffic(trails, lookups)
    settle(lookups.map(&:last), timeout: NOISE_WAIT_SECONDS)
    found = lookups.select { |_, lookup| lookup.fulfilled? }.map { |_, lookup| lookup.value }.reduce({}, :merge)
    trails.each { |trail| trail.noise = found.fetch(trail.osm_id, trail.noise) }
    trails.reject { |trail| NoiseService.too_loud?(trail.noise) }
  end

  # Lookups of the routes' terrain, near ones together so they share tiles, as
  # [routes, future] pairs.
  def self.terrain_lookups(trails, elevation)
    trails.sort_by { |trail| trail.midpoint.map { |degrees| (degrees.to_f / TERRAIN_CELL_DEGREES).floor } }
      .each_slice(TERRAIN_CHUNK).map { |chunk| [chunk, start { elevation.terrain(chunk) }] }
  end

  # The trails with their terrain, waiting at most TERRAIN_WAIT_SECONDS for
  # it. Trails whose terrain isn't found in time keep what was known of it, and
  # the lookups finish in the background for later searches.
  def self.with_terrain(trails, lookups)
    settle(lookups.map(&:last), timeout: TERRAIN_WAIT_SECONDS)
    found = lookups.select { |_, lookup| lookup.fulfilled? }.map { |_, lookup| lookup.value }.reduce({}, :merge)
    trails.each { |trail| trail.terrain = found.fetch(trail.osm_id, trail.terrain) }
  end

  # How far the routes climb and how far their high points stand above the land
  # around them. Routes whose terrain isn't found in time are ranked without it,
  # and the lookups finish in the background for later searches.
  def self.add_terrain(trails, elevation)
    with_terrain(trails, terrain_lookups(trails, elevation))
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
    length + scenic(trail) * SCENIC_WEIGHT + (trail.notable ? 0.5 : 0) - trail.paved.to_f * 2.5 -
      (OverpassService.generic_name?(trail.name) ? 1 : 0) - travel_penalty(round_trip_seconds(trail) / 3600.0) -
      trail.transfers.to_i * 0.1
  end

  # Where a hike is: the town or city and the state or region where transit
  # reaches it, as "Cold Spring, New York", with the country too when it isn't
  # the starting point's, or nil when nothing is mapped nearby. Raises when it
  # can't be looked up.
  def self.location(point, origin, places: PhotonService)
    here = places.locality(point.latitude, point.longitude) or return
    home = optional { places.locality(origin.latitude, origin.longitude) }
    country = here[:country] if home && here[:country] != home[:country]
    [here[:locality], here[:region], country].compact.uniq.join(", ").presence
  end

  # Day trips by train often take up to three hours there and back; longer ones count against a hike.
  def self.travel_penalty(hours)
    [hours - 3, 0].max * 0.25 + [hours - 6, 0].max * 0.5
  end

  # How scenic a route is, from 0 to about 10: its scenery, and quiet
  # surroundings up to QUIET_SCENIC more.
  def self.scenic(trail)
    (scenery(trail) + trail.noise&.dig(:quiet).to_f * QUIET_SCENIC).round(2)
  end

  # A route's views and waterfalls, from 0 to about 8: the best counts in full,
  # the next one half, and the one after a quarter, so one grand view outweighs
  # many small ones.
  def self.scenery(trail)
    waterfalls = Array(trail.highlights).select { |highlight| highlight[:kind] == "waterfall" }
    features = [views(trail), *waterfalls.map { |highlight| waterfall(highlight) }].sort.reverse
    features.first(3).each_with_index.sum { |value, index| value / 2**index }
  end

  # Whether a hike is shown: under 45 dB along most of it, where the noise map
  # says. Scenery only ranks hikes.
  def self.shown?(trail)
    !NoiseService.too_loud?(trail.noise)
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
  # Runs the block on the pool, its requests to providers as urgent as the caller's.
  def self.start(pool = Rails.configuration.x.provider_pool, &block)
    urgency = ProviderSlots.urgency
    Concurrent::Promises.future_on(pool) { ProviderSlots.with_priority(urgency) { Rails.application.executor.wrap(&block) } }
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
