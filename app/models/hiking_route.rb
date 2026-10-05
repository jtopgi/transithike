# A hiking route as the guide builds collected it (see RouteData).
class HikingRoute < ApplicationRecord
  self.primary_key = :osm_id
end
