require "uri"

# Hiking routes mapped in OpenStreetMap, from public Overpass API instances.
module OverpassService
  URLS = [
    "https://overpass-api.de/api/interpreter",
    # A public mirror, for when the main instance is too busy.
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
  ].freeze
  # The search area widens until it holds enough routes, so dense regions stay
  # local and sparse ones reach hikes farther away.
  SEARCH_RADII_METERS = [10_000, 20_000, 40_000, 80_000].freeze
  ENOUGH_ROUTES = 250
  # Transitous plans at most 128 destinations in one request.
  MAX_TRANSIT_ROUTES = 120
  # Each distance ring's upper bound in km and its share of the transit checks,
  # so farther hikes are checked even where nearby routes are plentiful.
  RINGS = [[15, 40], [35, 50], [Float::INFINITY, 30]].freeze
  # Routes this close together with the same name are sections of one trail.
  DUPLICATE_METERS = 5_000
  # Stops beyond the searched area are grouped into cells this many degrees
  # across, and routes are found within a cell's half diagonal and a half-hour
  # walk of its center, for at most MAX_FAR_CELLS cells.
  FAR_CELL_DEGREES = 0.05
  FAR_CELL_METERS = 5_500
  MAX_FAR_CELLS = 40
  # Routes spanning less are rarely hikes worth a trip.
  MIN_SPAN_METERS = 300
  # Shorter routes, and routes mostly on paved paths or roads, are walks rather than day hikes.
  MIN_LENGTH_MILES = 1.0
  MOSTLY_PAVED = 0.5
  # Longer routes are multi-day trails rather than hikes from a nearby start.
  MAX_LENGTH_MILES = 30
  METERS_PER_MILE = 1609.344
  # Mapped routes rarely change, so an area's routes are shared for a day and
  # each route's details for a week.
  AREA_CACHE_TTL = 1.day
  ROUTE_CACHE_TTL = 7.days
  # After an instance fails, searches start with the other one for a while.
  FAILOVER_KEY = "overpass:failover:v1"
  FAILOVER_TTL = 5.minutes
  PREVIEW_POINTS = 150
  # Mapped features worth a detour, found within 150 m of a route.
  HIGHLIGHT_TAGS = { "waterfall" => %w[waterway waterfall], "peak" => %w[natural peak],
    "viewpoint" => %w[tourism viewpoint] }.freeze
  HIGHLIGHT_METERS = 150
  # Previews cut corners, so matching highlights to them allows more room.
  PREVIEW_MATCH_METERS = 300
  MAX_HIGHLIGHTS = 12
  # Ways that are paved, or roads not marked unpaved, make a route a walk rather than a hike.
  PAVED_WAYS = [
    %(["surface"~"^(asphalt|concrete|concrete:plates|concrete:lanes|paved|paving_stones|sett|chipseal)$"]),
    %(["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road)$"]) +
      %(["surface"!~"^(unpaved|compacted|fine_gravel|gravel|pebblestone|dirt|earth|ground|grass|mud|sand|rock|wood|woodchips)$"]),
    %(["footway"="sidewalk"])
  ].freeze
  UNNAMED = "Unnamed hiking route".freeze
  # Names like "Trail 2" or "Fitness Loop" rarely mark a hike worth the trip.
  GENERIC_NAME = /\A(?:(?:trail|loop|path|route|track|section)\W*\w{0,3}|.*\b(?:fitness|exercise|connector|parcours)\b.*)\z/i
  # duration is in seconds; transfers is nil when walking the whole way is fastest.
  # paved is the share of the route's length on paved ways or roads, and loop is
  # true for routes that end where they start. arrival and last_return are the
  # times transit gets there and last leaves for the origin.
  Trail = Struct.new(:name, :summary, :latitude, :longitude, :length, :osm_id, :path, :highlights, :notable,
    :paved, :loop, :distance, :duration, :transfers, :arrival, :last_return, :origin, :area, :score,
    keyword_init: true) do
    # A point halfway along the route, in its area even where transit reaches it from town.
    def midpoint
      points = Array(path).flatten(1)
      points[points.size / 2] || [latitude, longitude]
    end
  end

  # The routes in the search area and its radius in meters, as { radius:, routes: }
  # with each route as { id:, name:, latitude:, longitude:, bounds:, span:, notable: }:
  # the center of its [south, west, north, east] bounding box, and its diagonal in meters.
  def self.candidates(lat:, lon:, connections: nil, cache: Rails.cache)
    unless SearchHttp.coordinates?(lat, lon)
      raise SearchErrors::InvalidInput, "The origin does not have valid coordinates."
    end

    # Rounding to about 5 km lets nearby searches share one query.
    center = [lat, lon].map { |value| (value.to_f * 20).round / 20.0 }
    cache.fetch("overpass:area:v2:#{center.join(':')}", expires_in: AREA_CACHE_TTL) do
      steps = SEARCH_RADII_METERS.map do |radius|
        %(relation(around:#{radius},#{center.join(',')})["type"="route"]["route"="hiking"]->.routes;) +
          "make search radius=#{radius}->.searched;"
      end
      widen = steps.drop(1).map { |step| "if (routes.count(relations) < #{ENOUGH_ROUTES}) { #{step} }" }
      query = "[out:json][timeout:20];#{steps.first}#{widen.join}.routes out tags bb;.searched out;"
      searched, routes = elements(query, connections, cache).partition do |element|
        element.is_a?(Hash) && element["type"] == "search"
      end
      tags = searched.first["tags"] if searched.one?
      radius = Integer(tags["radius"], exception: false) if tags.is_a?(Hash) && tags["radius"].is_a?(String)
      unless SEARCH_RADII_METERS.include?(radius)
        raise SearchErrors::UpstreamError, "The hiking route provider returned an incomplete response."
      end

      { radius: radius, routes: routes.filter_map { |element| candidate(element) } }
    end
  end

  # Routes near the reachable stops farther than beyond meters from the origin,
  # where trains, buses, and ferries go past the searched area. Each cell's
  # routes are cached, and only uncached cells are queried.
  def self.candidates_near(stops, lat:, lon:, beyond:, connections: nil, cache: Rails.cache)
    cells = far_cells(stops, lat, lon, beyond)
    keys = cells.to_h { |cell| [cell, "overpass:cell:v1:#{cell.join(':')}"] }
    found = keys.empty? ? {} : cache.read_multi(*keys.values)
    missing = cells.reject { |cell| found.key?(keys[cell]) }
    if missing.any?
      clauses = missing.map do |latitude, longitude|
        %(relation(around:#{FAR_CELL_METERS},#{latitude},#{longitude})["type"="route"]["route"="hiking"];)
      end
      routes = elements("[out:json][timeout:20];(#{clauses.join});out tags bb;", connections, cache)
        .filter_map { |element| candidate(element) }
      missing.each do |cell|
        found[keys[cell]] = routes.select { |route| distance_to_box(*cell, route[:bounds]) <= FAR_CELL_METERS }
        cache.write(keys[cell], found[keys[cell]], expires_in: AREA_CACHE_TTL)
      end
    end
    keys.values.flat_map { |key| found[key] }.uniq { |route| route[:id] }
  end

  # Cells [latitude, longitude] around the stops farther than beyond meters from
  # the origin. Where there are too many, cells with stations come first, and
  # each group is spread over travel times.
  def self.far_cells(stops, lat, lon, beyond)
    cells = stops.select { |stop| distance(lat, lon, stop[0], stop[1]) > beyond }.group_by do |stop|
      stop.first(2).map { |value| ((value / FAR_CELL_DEGREES).round * FAR_CELL_DEGREES).round(2) }
    end
    return cells.keys if cells.size <= MAX_FAR_CELLS

    stations, others = cells.sort_by { |_, grouped| grouped.map { |stop| stop[2] }.min }
      .partition { |_, grouped| grouped.any? { |stop| stop[4] } }.map { |group| group.map(&:first) }
    picked = spread(stations, MAX_FAR_CELLS)
    picked + spread(others, MAX_FAR_CELLS - picked.size)
  end

  # Up to count items, evenly spaced through the list.
  def self.spread(list, count)
    return list.first([count, 0].max) if list.size <= count || count <= 1

    (0...count).map { |index| list[(index * (list.size - 1).fdiv(count - 1)).round] }
  end

  # The routes with these ids, measured, leaving out those too short, too long,
  # or mostly paved for a day hike, and joined where transit reaches them
  # soonest when access is known; distance is in miles from the origin.
  def self.trails_for(ids, lat:, lon:, access: nil, connections: nil, cache: Rails.cache)
    routes(ids, connections, cache).filter_map do |trail|
      next unless trail.length.between?(MIN_LENGTH_MILES, MAX_LENGTH_MILES) && trail.paved.to_f < MOSTLY_PAVED

      if access
        trail.latitude, trail.longitude = access.access_point(trail.path)
        next unless trail.latitude
      end
      trail.distance = distance(lat, lon, trail.latitude, trail.longitude) / METERS_PER_MILE
      trail
    end
  end

  def self.candidate(element)
    tags = hiking_tags(element)
    bounds = element["bounds"] if tags
    corners = bounds.values_at("minlat", "minlon", "maxlat", "maxlon") if bounds.is_a?(Hash)
    return unless corners && SearchHttp.coordinates?(*corners.first(2)) && SearchHttp.coordinates?(*corners.last(2))

    # A route is at least as long as its bounding box's diagonal.
    span = distance(*corners)
    return unless span.between?(MIN_SPAN_METERS, MAX_LENGTH_MILES * METERS_PER_MILE)

    { id: element["id"], name: name(tags), latitude: (corners[0] + corners[2]) / 2.0,
      longitude: (corners[1] + corners[3]) / 2.0, bounds: corners, span: span.round, notable: notable?(tags) }
  end

  # Up to MAX_TRANSIT_ROUTES route ids, leaving out sections of one trail. With
  # access, the most promising routes transit may reach, keeping each trail's
  # quickest section; otherwise each distance ring's most promising routes, then
  # the nearest of the rest, keeping each trail's nearest section.
  def self.pick(candidates, lat:, lon:, access: nil)
    routes = candidates.map { |route| route.merge(meters: distance(lat, lon, route[:latitude], route[:longitude])) }
    if access
      reachable = routes.filter_map { |route| (minutes = access.reach(route[:bounds])) && route.merge(minutes: minutes) }
      return distinct(reachable.sort_by { |route| route[:minutes] })
        .sort_by { |route| [-promise(route), route[:minutes]] }.first(MAX_TRANSIT_ROUTES).pluck(:id)
    end

    unique = distinct(routes.sort_by { |route| route[:meters] })
    picked = RINGS.each_with_index.flat_map do |(limit, quota), index|
      floor = index.zero? ? 0 : RINGS[index - 1].first
      unique.select { |route| route[:meters] >= floor * 1000 && route[:meters] < limit * 1000 }
        .sort_by { |route| [-promise(route), route[:meters]] }.first(quota)
    end
    ids = picked.map { |route| route[:id] }
    (ids + (unique.map { |route| route[:id] } - ids)).first(MAX_TRANSIT_ROUTES)
  end

  # The routes, leaving out any named like an earlier one within DUPLICATE_METERS.
  def self.distinct(routes)
    seen = Hash.new { |names, key| names[key] = [] }
    routes.reject do |route|
      key = route[:name].to_s.downcase.gsub(/[^[:alnum:]]+/, "")
      repeat = key.present? && seen[key].any? do |other|
        distance(route[:latitude], route[:longitude], other[:latitude], other[:longitude]) < DUPLICATE_METERS
      end
      seen[key] << route unless repeat
      repeat
    end
  end

  # Notable routes of day-hike size with distinct names are likelier to be good hikes.
  def self.promise(route)
    (route[:notable] ? 1 : 0) + (route[:span] >= 800 ? 0.5 : 0) - (generic_name?(route[:name]) ? 1 : 0)
  end

  def self.generic_name?(name)
    name.nil? || name == UNNAMED || name.match?(GENERIC_NAME)
  end

  # Trails for the route ids, in order. Each route's details are cached, and
  # only uncached routes are queried.
  def self.routes(ids, connections, cache)
    return [] if ids.empty?

    keys = ids.to_h { |id| [id, "overpass:route:v2:#{id}"] }
    found = cache.read_multi(*keys.values)
    missing = ids.reject { |id| found.key?(keys[id]) }
    if missing.any?
      fetched = fetch_routes(missing, connections, cache)
      missing.each do |id|
        # Routes that cannot be measured are remembered too, so they are not queried again.
        found[keys[id]] = fetched.fetch(id, false)
        cache.write(keys[id], found[keys[id]], expires_in: ROUTE_CACHE_TTL)
      end
    end
    ids.filter_map { |id| Trail.new(**found[keys[id]]) if found[keys[id]] }
  end

  # Plain route attributes by id, never transit results, using the ids of each route's paved ways.
  def self.fetch_routes(ids, connections, cache)
    paved = PAVED_WAYS.map { |filter| "way.ways#{filter};" }
    query = "[out:json][timeout:20];relation(id:#{ids.join(',')})->.routes;.routes out geom;" \
      "way(r.routes)->.ways;(#{paved.join});out ids;"
    elements = elements(query, connections, cache).group_by { |element| element["type"] if element.is_a?(Hash) }
    paved = elements.fetch("way", []).pluck("id").to_set
    elements.except("way").values.flatten(1).each_with_object({}) do |element, routes|
      route = route_attributes(element, paved)
      routes[route[:osm_id]] = route if route
    end
  end

  # Highlights near each trail, as { osm_id => [{ kind:, name: }] }, waterfalls
  # first and named ones before unnamed ones. Each route's list is cached, and
  # only uncached routes are queried.
  def self.highlights(trails, connections: nil, cache: Rails.cache)
    return {} if trails.empty?

    keys = trails.to_h { |trail| [trail.osm_id, "overpass:highlights:v2:#{trail.osm_id}"] }
    found = cache.read_multi(*keys.values)
    missing = trails.reject { |trail| found.key?(keys[trail.osm_id]) }
    if missing.any?
      filters = HIGHLIGHT_TAGS.values.map { |key, value| %(node(around.ways:#{HIGHLIGHT_METERS})["#{key}"="#{value}"];) }
      query = "[out:json][timeout:20];relation(id:#{missing.map(&:osm_id).join(',')});way(r)->.ways;(#{filters.join});out;"
      points = elements(query, connections, cache).filter_map { |element| highlight_point(element) }
      missing.each do |trail|
        found[keys[trail.osm_id]] = highlights_near(trail.path, points)
        cache.write(keys[trail.osm_id], found[keys[trail.osm_id]], expires_in: ROUTE_CACHE_TTL)
      end
    end
    keys.transform_values { |key| found[key] }
  end

  def self.route_attributes(element, paved)
    tags = hiking_tags(element)
    members = element["members"]
    unless members.is_a?(Array) && members.all? { |member| member.is_a?(Hash) }
      raise SearchErrors::UpstreamError, "The hiking route provider returned invalid geometry."
    end
    return unless tags
    # Nested relations or missing geometry cannot yield a trustworthy length.
    return if members.any? { |member| member["type"] == "relation" }
    ways = members.select { |member| member["type"] == "way" }
    return if ways.empty? || ways.any? { |way| !way["ref"].is_a?(Integer) }
    ways = ways.uniq { |way| way["ref"] }
    return unless ways.all? { |way| valid_geometry?(way["geometry"]) }

    lengths = ways.map do |way|
      way["geometry"].each_cons(2).sum { |first, last| distance(first["lat"], first["lon"], last["lat"], last["lon"]) }
    end
    meters = lengths.sum
    return unless meters.positive?

    first_way = ways.first
    start = first_way["role"] == "backward" ? first_way["geometry"].last : first_way["geometry"].first
    # Every way end meets another in a loop, while a line has two loose ends.
    ends = ways.flat_map { |way| way["geometry"].values_at(0, -1) }.map { |point| [point["lat"], point["lon"]] }.tally
    {
      name: name(tags) || UNNAMED,
      summary: tags["description"].is_a?(String) ? tags["description"] : "A hiking route mapped by OpenStreetMap contributors.",
      latitude: start["lat"], longitude: start["lon"], length: meters / METERS_PER_MILE, osm_id: element["id"],
      path: preview_path(ways), notable: notable?(tags), loop: ends.values.all?(&:even?),
      paved: (ways.zip(lengths).sum { |way, length| paved.include?(way["ref"]) ? length : 0 } / meters).round(2)
    }
  end

  # A hiking route relation's tags, or nil for other relations.
  def self.hiking_tags(element)
    unless element.is_a?(Hash) && element["type"] == "relation" && element["id"].is_a?(Integer) &&
        element["id"].positive? && element["tags"].is_a?(Hash)
      raise SearchErrors::UpstreamError, "The hiking route provider returned an invalid route."
    end

    element["tags"] if element["tags"]["type"] == "route" && element["tags"]["route"] == "hiking"
  end

  def self.name(tags)
    tags["name"].strip if tags["name"].is_a?(String) && tags["name"].strip.present?
  end

  # Routes with a Wikipedia or Wikidata entry are notable enough to be documented.
  def self.notable?(tags)
    %w[wikidata wikipedia].any? { |key| tags[key].is_a?(String) && tags[key].strip.present? }
  end

  def self.highlight_point(node)
    tags = node["tags"] if node.is_a?(Hash) && node["type"] == "node"
    return unless tags.is_a?(Hash) && SearchHttp.coordinates?(node["lat"], node["lon"])

    kind = HIGHLIGHT_TAGS.find { |_, (key, value)| tags[key] == value }&.first
    { kind: kind, name: name(tags)&.truncate(60), latitude: node["lat"], longitude: node["lon"] } if kind
  end

  def self.highlights_near(path, points)
    boxes = path.map { |line| bounding_box(line) }
    points.select { |point| path.each_with_index.any? { |line, index| near_line?(point, line, boxes[index]) } }
      .uniq { |point| [point[:kind], point[:name] || [point[:latitude], point[:longitude]]] }
      .sort_by { |point| [HIGHLIGHT_TAGS.keys.index(point[:kind]), point[:name] ? 0 : 1] }
      .first(MAX_HIGHLIGHTS).map { |point| point.slice(:kind, :name) }
  end

  # Whether the point is within PREVIEW_MATCH_METERS of a [[latitude, longitude], ...] line.
  def self.near_line?(point, line, (south, west, north, east))
    scale = Math.cos(point[:latitude] * Math::PI / 180)
    margin = PREVIEW_MATCH_METERS / 110_574.0
    return false unless point[:latitude].between?(south - margin, north + margin) &&
      point[:longitude].between?(west - margin / [scale, 0.01].max, east + margin / [scale, 0.01].max)

    # Meters east and north of the point, which is accurate enough over a few hundred meters.
    projected = line.map do |latitude, longitude|
      [(longitude - point[:longitude]) * scale * 111_320, (latitude - point[:latitude]) * 110_574]
    end
    return Math.hypot(*projected.first) <= PREVIEW_MATCH_METERS if projected.one?

    projected.each_cons(2).any? { |first, last| segment_distance(first, last) <= PREVIEW_MATCH_METERS }
  end

  # The distance from the origin to the segment between two projected points.
  def self.segment_distance((x1, y1), (x2, y2))
    dx, dy = x2 - x1, y2 - y1
    squared = dx * dx + dy * dy
    along = squared.zero? ? 0 : (-(x1 * dx + y1 * dy) / squared).clamp(0, 1)
    Math.hypot(x1 + along * dx, y1 + along * dy)
  end

  def self.bounding_box(line)
    latitudes, longitudes = line.map(&:first), line.map(&:last)
    [latitudes.min, longitudes.min, latitudes.max, longitudes.max]
  end

  # The response's elements, from the preferred instance or else the other one.
  def self.elements(query, connections, cache)
    connections ||= urls(cache).map { |url| SearchHttp.connection(url, timeout: 25) }
    connections.each_with_index do |connection, index|
      return request(connection, query)
    rescue SearchErrors::UpstreamError
      cache.write(FAILOVER_KEY, !cache.read(FAILOVER_KEY), expires_in: FAILOVER_TTL) if index.zero?
      raise if index == connections.size - 1
    end
  end

  def self.urls(cache)
    cache.read(FAILOVER_KEY) ? URLS.reverse : URLS
  end

  def self.request(connection, query)
    response = SearchHttp.json do
      connection.post do |request|
        request.body = URI.encode_www_form(data: query)
        request.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
    end
    unless response["elements"].is_a?(Array) && !response.key?("remark")
      raise SearchErrors::UpstreamError, "The hiking route provider returned an incomplete response."
    end

    response["elements"]
  end

  # Downsampled [[latitude, longitude], ...] lines, enough to draw a route preview.
  def self.preview_path(ways)
    step = [(ways.sum { |way| way["geometry"].length } / PREVIEW_POINTS.to_f).ceil, 1].max
    ways.map do |way|
      points = way["geometry"].each_slice(step).map(&:first)
      points << way["geometry"].last unless points.last.equal?(way["geometry"].last)
      points.map { |point| [point["lat"].round(5), point["lon"].round(5)] }
    end
  end

  def self.valid_geometry?(geometry)
    geometry.is_a?(Array) && geometry.length >= 2 && geometry.all? do |point|
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
    end
  end

  def self.distance_to_box(latitude, longitude, (south, west, north, east))
    distance(latitude, longitude, latitude.clamp(south, north), longitude.clamp(west, east))
  end

  def self.distance(lat1, lon1, lat2, lon2)
    radians = Math::PI / 180
    a = Math.sin((lat2 - lat1) * radians / 2)**2 +
      Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin((lon2 - lon1) * radians / 2)**2
    6_371_000 * 2 * Math.asin(Math.sqrt(a.clamp(0, 1)))
  end
end
