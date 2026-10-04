# Bounds concurrent requests to the free map, place, and transit providers
# across all searches. Defined here so code reloading doesn't leak pools.
Rails.application.config.x.provider_pool = Concurrent::FixedThreadPool.new(6)
# Public Overpass instances allow each client only a couple of queries at once.
Rails.application.config.x.overpass_slots = Concurrent::Semaphore.new(2)
# Hiking-route lookups that run alongside other work wait for those slots on
# threads of their own, not the shared pool's.
Rails.application.config.x.overpass_pool = Concurrent::CachedThreadPool.new
# Searches plan each hike's trips there and back, at most three hikes at once,
# so they don't hold up the other lookups waiting for Transitous.
Rails.application.config.x.trip_pool = Concurrent::FixedThreadPool.new(3)
# Searches from stations run in the background, at most three at once, so a
# visitor's search shares them with others and they finish after visitors leave.
Rails.application.config.x.station_pool = Concurrent::FixedThreadPool.new(3)
# Transitous answers at most three requests at once from a client, and turns
# away more, so requests to it wait for one of three slots.
Rails.application.config.x.provider_slots = { "api.transitous.org" => Concurrent::Semaphore.new(3) }
