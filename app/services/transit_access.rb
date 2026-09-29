# Estimated trips from an origin to any point: to a transit stop reachable from
# the origin, then on foot. The estimates choose which routes are worth
# checking and where each route is quickest to join; the transit planner then
# times those trips exactly.
class TransitAccess
  # Walking at 4.5 km/h, where streets and paths are about 30% longer than a straight line.
  WALK_METERS_PER_MINUTE = 75.0
  DETOUR = 1.3
  # Like the transit planner, walking all the way or from the last stop takes at most half an hour.
  MAX_WALK_MINUTES = TransitousService::MAX_POST_TRANSIT_SECONDS / 60
  MAX_TRIP_MINUTES = TransitousService::MAX_TRAVEL_MINUTES
  WALK_METERS = MAX_WALK_MINUTES * WALK_METERS_PER_MINUTE / DETOUR
  CELL_DEGREES = 0.02

  # stops are [latitude, longitude, minutes] from the origin, followed by anything.
  def initialize(latitude, longitude, stops)
    @origin = [latitude, longitude, 0]
    @cells = stops.group_by { |stop| cell(stop[0], stop[1]) }
  end

  # Estimated minutes to the nearest point of a [south, west, north, east] box, or nil.
  def reach(box)
    quickest(box) { |stop| [meters(stop[0], stop[1], stop[0].clamp(box[0], box[2]), stop[1].clamp(box[1], box[3]))] }&.first
  end

  # The [latitude, longitude] of the path point that is quickest to reach, or nil.
  def access_point(path)
    points = path.flatten(1)
    latitudes, longitudes = points.map(&:first), points.map(&:last)
    box = [latitudes.min, longitudes.min, latitudes.max, longitudes.max]
    quickest(box) do |stop|
      points.map { |point| [meters(stop[0], stop[1], *point), point] }.min_by(&:first)
    end&.last
  end

  private

  # The quickest [minutes, point] over walking from the origin and from each stop
  # near the box, where the block gives the meters walked from a stop and to where.
  def quickest(box)
    best = nil
    [@origin, *stops_near(box).sort_by { |stop| stop[2] }].each do |stop|
      # Walking only adds time, so stops reached later cannot do better.
      break if best && stop[2] >= best.first

      walked, point = yield(stop)
      walk = walked * DETOUR / WALK_METERS_PER_MINUTE
      minutes = stop[2] + walk
      next if walk > MAX_WALK_MINUTES || minutes > MAX_TRIP_MINUTES

      best = [minutes, point] if best.nil? || minutes < best.first
    end
    best
  end

  def stops_near(box)
    margin = WALK_METERS / 110_574
    margin_east = margin / [Math.cos((box[0] + box[2]) / 2 * Math::PI / 180), 0.01].max
    south, west = cell(box[0] - margin, box[1] - margin_east)
    north, east = cell(box[2] + margin, box[3] + margin_east)
    (south..north).flat_map { |row| (west..east).flat_map { |column| @cells.fetch([row, column], []) } }
  end

  def cell(latitude, longitude)
    [(latitude / CELL_DEGREES).floor, (longitude / CELL_DEGREES).floor]
  end

  # Straight-line meters, accurate enough over walking distances.
  def meters(lat1, lon1, lat2, lon2)
    Math.hypot((lon2 - lon1) * Math.cos((lat1 + lat2) / 2 * Math::PI / 180) * 111_320, (lat2 - lat1) * 110_574)
  end
end
