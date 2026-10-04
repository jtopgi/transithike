# A search for hikes by train from one station on one day, shared by every
# search that starts there while it runs, and kept for later ones once done.
# It runs in the background, so it finishes, and is kept, even when the
# visitors who started it leave.
class StationSearch
  # Complete searches are kept for hours, and searches that couldn't check
  # some routes only for a minute, so they're tried again soon.
  KEEP = 12.hours
  KEEP_INCOMPLETE = 1.minute

  # Searches running in this process, by what they search and with what.
  RUNNING = Concurrent::Map.new

  # The station's search for hikes leaving at departure_time: the kept one, or
  # the one running, or else a new one, started on the pool.
  def self.start(station, departure_time, transit: TransitousService, hiking: OverpassService,
    elevation: ElevationService, cache: Rails.cache, pool: Rails.configuration.x.station_pool)
    key = "station-search:v1:#{station.key}:#{departure_time.utc.iso8601}"
    kept = cache.read(key)
    return finished(kept) if kept

    started = nil
    running = RUNNING.compute_if_absent([key, transit, hiking, elevation]) do
      started = new(station, departure_time, key, { transit: transit, hiking: hiking, elevation: elevation }, cache)
    end
    # Only once it's listed does it run, so it can't finish before it's listed.
    started&.run(pool)
    running
  end

  # A search that's already done, with its result.
  def self.finished(result)
    new(nil, nil, nil, nil, nil, events: [[:trails, result.trails.map(&:dup)], [:done, result]], done: true)
  end

  def initialize(station, departure_time, key, providers, cache, events: [], done: false)
    @station, @departure_time, @key, @providers, @cache = station, departure_time, key, providers, cache
    @events, @done, @lock = events, done, Mutex.new
  end

  # What the search found from the index-th event on, as [[event, payload], ...]
  # like TrailsService.from_station's, then [:done, result] once it's done, or
  # [:failed, error] when it fails, and whether it's done.
  def events_since(index)
    @lock.synchronize { [@events.drop(index), @done] }
  end

  def run(pool)
    Concurrent::Promises.future_on(pool) do
      Rails.application.executor.wrap { search }
    ensure
      RUNNING.delete_pair([@key, *@providers.values], self)
    end
  end

  private

  def search
    result = TrailsService.from_station(@station, @departure_time, **@providers) { |event, payload| record(event, payload) }
    @cache.write(@key, result, expires_in: result.complete && result.returns_checked ? KEEP : KEEP_INCOMPLETE)
    record(:done, result)
  rescue SearchErrors::UpstreamError => error
    record(:failed, error)
  rescue StandardError => error
    Rails.logger.error("Search from #{@station.name} failed: #{error.class}: #{error.message}")
    record(:failed, SearchErrors::UpstreamError.new(SearchHttp::UNAVAILABLE_MESSAGE))
  ensure
    finish
  end

  def record(event, payload)
    @lock.synchronize { @events << [event, payload] }
  end

  def finish
    @lock.synchronize { @done = true }
  end
end
