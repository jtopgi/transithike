# Bounds concurrent requests to the free map, place, and transit providers
# across all searches. Defined here so code reloading doesn't leak pools.
Rails.application.config.x.provider_pool = Concurrent::FixedThreadPool.new(6)
