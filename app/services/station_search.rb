# A search for hikes by train from one station on one day, shared by every
# search that starts there while it runs, and kept for later ones once done.
# It runs in the background, so it finishes, and is kept, even when the
# visitors who started it leave. Kept searches are served at once, and searched
# again in the background once they're REFRESH_AFTER old, or
# REFRESH_INCOMPLETE_AFTER when some routes couldn't be checked. Where the
# station hasn't been searched for the day yet, its last search for the same
# weekday and time, from up to two weeks before, is served at once, moved to
# the day, while the day is searched in the background: timetables rarely
# change from one week to the next, and each card plans its trips for the day.
# Searches visitors wait on run on the stations' pool, ahead of background ones
# for providers, and searching again in the background runs on a pool of its
# own (see config/initializers/provider_pool.rb).
class StationSearch
  KEEP = 8.days
  REFRESH_AFTER = 12.hours
  REFRESH_INCOMPLETE_AFTER = 10.minutes
  EARLIER_WEEKS_KEEP = 15.days
  # Searches in the background are left for a later visit while this many
  # searches are already waiting for the pool, and a station isn't searched in
  # the background again within REFRESH_INCOMPLETE_AFTER of the last try.
  MAX_WAITING = 2
  # Kept searches hold these structs.
  SHAPE = CacheShape.of(TrailsService::Result, OverpassService::Trail, Station, Place)

  # Searches running in this process, by what they search and with what.
  RUNNING = Concurrent::Map.new

  # The station's search for hikes leaving at departure_time: a kept one, or
  # an earlier week's, served at once and searched again on background_pool,
  # or the one running, or else a new one, started on the pool. With fresh, as
  # for guides and keeping searches ready, kept searches are only served while
  # they're complete and less than REFRESH_AFTER old, and earlier weeks' never.
  def self.start(station, departure_time, fresh: false, transit: TransitousService, hiking: OverpassService,
    elevation: ElevationService, noise: NoiseService, cache: Rails.cache, pool: Rails.configuration.x.station_pool,
    background_pool: Rails.configuration.x.background_pool)
    search = { station: station, departure_time: departure_time, keys: keys(station, departure_time), cache: cache,
      providers: { transit: transit, hiking: hiking, elevation: elevation, noise: noise } }
    kept = cache.read(search[:keys][:day])
    if kept && !(fresh && (stale?(kept) || !complete?(kept[:result])))
      refresh(**search, pool: background_pool) if stale?(kept)
      return finished(kept[:result])
    end
    unless fresh || kept
      earlier = cache.read(search[:keys][:weekday])
      if earlier && earlier[:result].departure_time < departure_time
        refresh(**search, pool: background_pool)
        return finished(moved(earlier[:result], departure_time))
      end
    end
    running(**search, pool: pool)
  end

  # The cache keys of the station's search for the day, and of its latest
  # search for the same weekday and time.
  def self.keys(station, departure_time)
    zone = departure_time.time_zone.tzinfo.name
    { day: "station-search:v3:#{SHAPE}:#{station.key}:#{departure_time.utc.iso8601}",
      weekday: "station-search:weekday:v2:#{SHAPE}:#{station.key}:#{zone}:#{departure_time.strftime('%a %H:%M')}",
      tried: "station-search:tried:v1:#{station.key}:#{departure_time.utc.iso8601}" }
  end

  def self.complete?(result)
    result.complete && result.returns_checked
  end

  def self.stale?(kept)
    kept[:found_at] < (complete?(kept[:result]) ? REFRESH_AFTER : REFRESH_INCOMPLETE_AFTER).ago
  end

  # The station's search running in this process, or a new one, started on the
  # pool. When urgent, as when a visitor waits on it, its requests go ahead of
  # background work's, and one still waiting for the background pool starts
  # on the pool at once.
  def self.running(station:, departure_time:, keys:, cache:, providers:, pool:,
    urgent: ProviderSlots.priority == ProviderSlots::VISITOR)
    started = nil
    search = RUNNING.compute_if_absent([keys[:day], *providers.values]) do
      started = new(station, departure_time, keys, providers, cache)
    end
    search.urgent! if urgent
    # Only once it's listed does it run, so it can't finish before it's listed,
    # and a search that can't start isn't left listed, for others to wait on.
    if started
      begin
        started.run(pool)
      rescue StandardError
        RUNNING.delete_pair([keys[:day], *providers.values], started)
        raise
      end
      cache.write(keys[:tried], true, expires_in: REFRESH_INCOMPLETE_AFTER)
    elsif urgent && !search.started?
      search.run(pool)
    end
    search
  end

  # Searches the station again in the background, unless it was tried
  # recently or the pool already has enough waiting.
  def self.refresh(pool:, cache:, keys:, **search)
    return if cache.exist?(keys[:tried]) || (pool.respond_to?(:queue_length) && pool.queue_length >= MAX_WAITING)

    running(pool: pool, cache: cache, keys: keys, urgent: false, **search)
  end

  # An earlier week's search as if for departure_time, its times moved by whole
  # weeks, without the hikes the days drawing in leave too little daylight for.
  def self.moved(result, departure_time)
    shift = departure_time - result.departure_time
    trails = result.trails.map do |trail|
      trail.dup.tap do |moved|
        moved.arrival &&= moved.arrival + shift
        moved.last_return &&= moved.last_return + shift
        moved.sunset = Daylight.sunset(departure_time, moved.latitude, moved.longitude)
      end
    end.select { |trail| TrailsService.daylight?(trail) }
    result.dup.tap do |moved|
      moved.departure_time = departure_time
      moved.return_by = departure_time.change(hour: TrailsService::RETURN_BY_HOUR)
      moved.trails = trails
    end
  end

  # A search that's already done, with its result, without hikes that aren't
  # shown now, as when a search kept from before left them in.
  def self.finished(result)
    result.trails = result.trails.select { |trail| TrailsService.shown?(trail) }
    new(nil, nil, nil, nil, nil, events: [[:trails, result.trails.map(&:dup)], [:done, result]], done: true)
  end

  def initialize(station, departure_time, keys, providers, cache, events: [], done: false)
    @station, @departure_time, @keys, @providers, @cache = station, departure_time, keys, providers, cache
    @events, @done, @lock = events, done, Mutex.new
    @urgent, @started = Concurrent::AtomicBoolean.new, Concurrent::AtomicBoolean.new
  end

  # A visitor waits on the search, so its requests go ahead of background work's.
  def urgent!
    @urgent.make_true
  end

  # How urgent the search's requests to providers are (see ProviderSlots).
  def provider_priority
    @urgent.true? ? ProviderSlots::SEARCH : ProviderSlots::BACKGROUND
  end

  def started?
    @started.true?
  end

  # What the search found from the index-th event on, as [[event, payload], ...]
  # like TrailsService.from_station's, then [:done, result] once it's done, or
  # [:failed, error] when it fails, and whether it's done.
  def events_since(index)
    @lock.synchronize { [@events.drop(index), @done] }
  end

  # Searches on the pool, unless it already started on another.
  def run(pool)
    Concurrent::Promises.future_on(pool) do
      next unless @started.make_true

      begin
        ProviderSlots.with_priority(self) { Rails.application.executor.wrap { search } }
      ensure
        RUNNING.delete_pair([@keys[:day], *@providers.values], self)
      end
    end
  end

  private

  def search
    result = TrailsService.from_station(@station, @departure_time, **@providers) { |event, payload| record(event, payload) }
    earlier = with_earlier(result)
    record(:trails, earlier.map(&:dup)) if earlier.any?
    entry = { result: result, found_at: Time.current }
    @cache.write(@keys[:day], entry, expires_in: KEEP)
    @cache.write(@keys[:weekday], entry, expires_in: EARLIER_WEEKS_KEEP) if result.trails.any?
    record(:done, result)
  rescue SearchErrors::UpstreamError => error
    record(:failed, error)
  rescue StandardError => error
    Rails.logger.error("Search from #{@station.name} failed: #{error.class}: #{error.message}")
    record(:failed, SearchErrors::UpstreamError.new(SearchHttp::UNAVAILABLE_MESSAGE))
  ensure
    finish
  end

  # When the search couldn't check some routes, it keeps those the day's last
  # search found that it didn't, ranking them all again, and returns them.
  # Those found too loud since, as when this search found them so, and those
  # that aren't shown now stay hidden.
  def with_earlier(result)
    return [] if self.class.complete?(result)

    earlier = @cache.read(@keys[:day])&.dig(:result)
    found = result.trails.to_set(&:osm_id)
    extra = Array(earlier&.trails).reject { |trail| found.include?(trail.osm_id) }
    noise = TrailsService.noise_at(@station, @providers[:noise])
    extra = TrailsService.away_from_traffic(extra, TrailsService.noise_lookups(extra, noise)) if noise && extra.any?
    extra = extra.select { |trail| TrailsService.shown?(trail) }
    result.trails = TrailsService.rank(result.trails + extra) if extra.any?
    extra
  end

  def record(event, payload)
    @lock.synchronize { @events << [event, payload] }
  end

  def finish
    @lock.synchronize { @done = true }
  end
end
