# Bounds concurrent requests to the free map, place, and transit providers
# across all searches. Defined here so code reloading doesn't leak pools.
Rails.application.config.x.provider_pool = Concurrent::FixedThreadPool.new(6)
# Public Overpass instances allow each client only a couple of queries at once,
# so hiking-route lookups run on their own pool, where extra queries wait in its
# queue rather than holding the shared pool's threads.
Rails.application.config.x.overpass_pool = Concurrent::FixedThreadPool.new(2)
