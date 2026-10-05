# Keeps searches from the US guide cities ready, where most visitors are, so
# the first visitor near one of their stations doesn't wait: every WARM_EVERY,
# each city's major stations are searched for the next Saturday and Sunday,
# one at a time, unless their kept searches are recent and complete, in the
# background, behind searches visitors wait on. config/puma.rb starts it in
# the web server when WARM_SEARCHES is 1.
module SearchWarmer
  # The first round waits for the server to settle in, as after a deploy.
  FIRST_WAIT = 2.minutes
  # Kept searches go stale after StationSearch::REFRESH_AFTER, but searching
  # them again more often than this would keep Transitous busy all day.
  WARM_EVERY = 1.day
  # A station's search that takes longer is left to finish on its own.
  STATION_WAIT = 15.minutes

  def self.start(log: Rails.logger)
    Thread.new do
      sleep FIRST_WAIT
      loop do
        begin
          warm
        rescue StandardError => error
          log.error("Searches weren't kept ready: #{error.class}: #{error.message}")
        end
        sleep WARM_EVERY
      end
    end
  end

  # Searches each guide city's major stations for the next Saturday and
  # Sunday, one station at a time, returning how many were searched. Each
  # station's search runs on the pool, and is only waited for here.
  # The guide cities whose searches are kept ready: those in the US.
  def self.cities(guides = GuideService.guides)
    zones = TZInfo::Country.get("US").zone_identifiers
    guides.select { |guide| zones.include?(guide.time_zone) }
  end

  def self.warm(guides: cities, transit: TransitousService, searches: StationSearch, log: Rails.logger,
    wait: STATION_WAIT, pool: Rails.configuration.x.background_pool)
    guides.product(TrailsService::WEEKEND_DAYS.keys).sum do |guide, day|
      departure = TrailsService.departure_time(guide.time_zone, day: day)
      stations = Rails.application.executor.wrap { transit.major_stations(origin: guide.place, departure_time: departure) }
      stations.count do |station|
        search = Rails.application.executor.wrap { searches.start(station, departure, fresh: true, transit: transit, pool: pool) }
        finished?(search, wait)
      end
    rescue StandardError => error
      log.warn("Searches from #{guide.name} for #{day} weren't kept ready: #{error.class}: #{error.message}")
      0
    end
  end

  # Waits for the search to finish, at most seconds, and returns whether it did.
  def self.finished?(search, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until search.events_since(0).last
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 1
    end
    true
  end
end
