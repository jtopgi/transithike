# The hiking routes the guide builds collected (see RouteData), which
# OverpassService, ElevationService, and NoiseService read where their caches
# have none, so searches don't need providers for them. Each lookup gives
# what's stored, by tile or route id, and nothing when the database can't
# be read.
module RouteStore
  class << self
    # Whether the database is read, as it isn't by guide builds, which collect what it holds.
    attr_writer :enabled

    def enabled?
      @enabled != false
    end
  end

  # The tiles' routes, as OverpassService.fetch_tiles keeps them, by tile.
  def self.tiles(tiles)
    return {} if tiles.empty? || !enabled?

    by_key = tiles.index_by { |tile| tile.join(":") }
    RouteTile.where(key: by_key.keys).to_h do |stored|
      [by_key[stored.key], { routes: stored.routes.map(&:deep_symbolize_keys), at: stored.collected_at }]
    end
  rescue ActiveRecord::ActiveRecordError
    {}
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
    return {} if ids.empty? || !enabled?

    HikingRoute.where(osm_id: ids).where.not(column => nil).pluck(:osm_id, column).to_h { |id, value| [id, yield(value)] }
  rescue ActiveRecord::ActiveRecordError
    {}
  end
end
