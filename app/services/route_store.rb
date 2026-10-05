# The hiking routes the guide builds collected (see RouteData), which
# OverpassService, ElevationService, and NoiseService read where their caches
# have none, so searches don't need providers for them. Each lookup gives
# what's stored, by tile or route id, and nothing when the database can't
# be read. Like the cache (see config/initializers/solid_cache.rb), a
# database that can't be reached is left alone for FailOpenCache::PAUSE_SECONDS,
# so that each lookup doesn't wait out the connection's timeout meanwhile.
module RouteStore
  class << self
    # Whether the database is read, as it isn't by guide builds, which collect what it holds.
    attr_writer :enabled

    def enabled?
      @enabled != false
    end

    # Ends a pause, so the next lookup reads the database.
    def reachable!
      @unreachable_until = nil
    end

    private

    def unreachable?
      @unreachable_until && Process.clock_gettime(Process::CLOCK_MONOTONIC) < @unreachable_until
    end

    def unreachable!
      @unreachable_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FailOpenCache::PAUSE_SECONDS
    end
  end

  # The tiles' routes, as OverpassService.fetch_tiles keeps them, by tile.
  def self.tiles(tiles)
    return {} if tiles.empty?

    by_key = tiles.index_by { |tile| tile.join(":") }
    read do
      RouteTile.where(key: by_key.keys).to_h do |stored|
        [by_key[stored.key], { routes: stored.routes.map(&:deep_symbolize_keys), at: stored.collected_at }]
      end
    end
  end

  # The routes' attributes for a Trail, or false for those that can't be measured, by id.
  def self.details(ids)
    stored(ids, :details) { |details| details && details.deep_symbolize_keys }
  end

  def self.highlights(ids)
    stored(ids, :highlights) { |highlights| highlights.map(&:deep_symbolize_keys) }
  end

  def self.terrain(ids)
    stored(ids, :terrain, &:deep_symbolize_keys)
  end

  def self.noise(ids)
    stored(ids, :noise, &:deep_symbolize_keys)
  end

  # The column's values for the routes that have one, each as the block reads it.
  def self.stored(ids, column)
    return {} if ids.empty?

    read do
      HikingRoute.where(osm_id: ids).where.not(column => nil).pluck(:osm_id, column).to_h { |id, value| [id, yield(value)] }
    end
  end

  # What the block reads from the database, or nothing when it isn't read or can't be.
  def self.read
    return {} if !enabled? || unreachable?

    yield
  rescue *FailOpenCache::UNREACHABLE
    unreachable!
    {}
  rescue ActiveRecord::ActiveRecordError
    {}
  end
  private_class_method :read
end
