# Hiking routes as OpenStreetMap maps them, with what's known about them, and
# the routes of each map tile, as the weekly guide builds collect them where
# Overpass answers (see RouteData), so searches read them rather than ask it.
class CreateHikingRoutes < ActiveRecord::Migration[8.1]
  def change
    create_table :hiking_routes, id: false do |t|
      t.bigint :osm_id, null: false, primary_key: true
      # A Trail's attributes, or false for a route that can't be measured.
      t.jsonb :details
      t.jsonb :highlights
      t.jsonb :terrain
      t.jsonb :noise
      t.datetime :collected_at, null: false
    end

    create_table :route_tiles, id: false do |t|
      # The tile's south and west edges, as "47.5:-122.5".
      t.string :key, null: false, primary_key: true
      t.jsonb :routes, null: false
      t.datetime :collected_at, null: false
    end
  end
end
