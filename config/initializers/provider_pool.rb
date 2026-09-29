# Bounds concurrent requests to the free map, place, and transit providers
# across all searches. Defined here so code reloading doesn't leak pools.
Rails.application.config.x.provider_pool = Concurrent::FixedThreadPool.new(6)
# Public Overpass instances allow each client only a couple of queries at once.
Rails.application.config.x.overpass_slots = Concurrent::Semaphore.new(2)
# Hiking-route lookups that run alongside other work wait for those slots on
# threads of their own, not the shared pool's.
Rails.application.config.x.overpass_pool = Concurrent::CachedThreadPool.new
