require "uri"

# Hiking routes mapped in OpenStreetMap, from public Overpass API instances.
module OverpassService
  URLS = [
    "https://overpass-api.de/api/interpreter",
    # A public mirror, for when the main instance is too busy.
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
  ].freeze
  # Routes are found in tiles this many degrees across that hold routes within
  # a walk of the stations. Each tile's routes are shared by every search for days.
  TILE_DEGREES = 0.5
  # At most this many tiles are searched in each band of travel time, the
  # quickest first, so the scenery farther out is searched as well as the nearest.
  TILE_BANDS = [[120, 8], [180, 7], [Float::INFINITY, 5]].freeze
  MAX_TILES = TILE_BANDS.sum(&:last)
  # Where hiking routes are plentiful, as in the Alps, a tile lists a
  # megabyte of them, so a query lists at most this many tiles.
  TILES_PER_QUERY = 4
  TILE_CACHE_TTL = 3.days
  # Regions' routes and routes' geometry take a while to find, especially on the mirror.
  LONG_QUERY_SECONDS = 45
  # Trips are checked for at most this many routes per search, in batches; Transitous
  # plans at most 128 destinations in one request.
  MAX_TRANSIT_ROUTES = 120
  # Routes this close together with the same name are sections of one trail.
  DUPLICATE_METERS = 5_000
  # Routes spanning less are rarely hikes worth a trip.
  MIN_SPAN_METERS = 300
  # Shorter routes, and routes mostly on paved paths or roads, are walks rather than day hikes.
  MIN_LENGTH_MILES = 1.0
  MOSTLY_PAVED = 0.5
  # Longer routes are multi-day trails rather than hikes from a nearby start.
  MAX_LENGTH_MILES = 30
  METERS_PER_MILE = 1609.344
  # Mapped routes rarely change, so each route's details are shared for a week.
  ROUTE_CACHE_TTL = 7.days
  # After an instance fails, searches start with the other one for a while.
  FAILOVER_KEY = "overpass:failover:v1"
  FAILOVER_TTL = 5.minutes
  # Queries wait this long for one of the process's Overpass slots.
  SLOT_WAIT_SECONDS = 30
  # Tiles and routes being looked up in this process, by cache key, so
  # searches that need the same ones at once ask Overpass once, and wait at
  # most SHARED_WAIT_SECONDS for another search's lookup.
  LOOKING_UP = Concurrent::Map.new
  SHARED_WAIT_SECONDS = 90
  # When both instances turn a query away quickly, as they do when briefly
  # overloaded, the preferred one is asked once more after a pause
  # (config.x.overpass_retry_pause_seconds).
  QUICK_FAILURE_SECONDS = 15
  # Highlights only refine a search: they are looked up when a slot is free, and briefly.
  HIGHLIGHT_TIMEOUT_SECONDS = 15
  BUSY = "The hiking route provider is busy. Please try again later.".freeze
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
  # times transit gets there and last leaves for the origin. terrain is the
  # route's { climb:, relief: } in meters, from ElevationService. plan is how
  # it's hiked, :loop, :out_and_back, or :through to finish, the
  # [latitude, longitude] of its far end, where the trip back leaves. station
  # is the Station the trips there leave from and the trips back return to.
  Trail = Struct.new(:name, :summary, :latitude, :longitude, :length, :osm_id, :path, :highlights, :notable,
    :paved, :loop, :distance, :duration, :transfers, :arrival, :last_return, :origin, :terrain, :score, :plan, :finish,
    :location, :station, keyword_init: true) do
    # A point halfway along the route, in its area even where transit reaches it from town.
    def midpoint
      points = Array(path).flatten(1)
      points[points.size / 2] || [latitude, longitude]
    end

    # The route's middle, then points a sixth of the way from each end, to
    # about 1 km, where photos taken along it are looked for.
    def photo_points
      points = Array(path).flatten(1)
      along = [1.0 / 6, 5.0 / 6].map { |share| points[(share * (points.size - 1)).round] } if points.size > 1
      [midpoint, *along].map { |latitude, longitude| [latitude.round(2), longitude.round(2)] }.uniq
    end

    # The two loose ends of the route's ways that are farthest apart, as
    # [latitude, longitude] pairs, or nil when every way's end meets another's.
    def ends
      loose = Array(path).flat_map { |line| [line.first, line.last] }.tally.select { |_, count| count.odd? }.keys
      loose.combination(2).max_by { |first, last| OverpassService.distance(*first, *last) } if loose.size >= 2
    end
  end

  # The [south, west] corners of tiles holding routes within a walk of the
  # stations, [latitude, longitude, minutes] from the origin: those with the
  # quickest stations first, and at most each TILE_BANDS band's share of them.
  def self.tiles(stations)
    reach = TransitAccess::WALK_METERS / 110_574.0
    quickest = {}
    stations.each do |latitude, longitude, minutes|
      reach_east = reach / [Math.cos(latitude * Math::PI / 180), 0.01].max
      rows = tile_index(latitude - reach)..tile_index(latitude + reach)
      columns = tile_index(longitude - reach_east)..tile_index(longitude + reach_east)
      rows.to_a.product(columns.to_a).each do |tile|
        quickest[tile] = [quickest.fetch(tile, minutes), minutes].min
      end
    end
    tiles = quickest.sort_by { |tile, minutes| [minutes, tile] }
    floor = 0
    picked = TILE_BANDS.flat_map do |limit, share|
      band = tiles.select { |_, minutes| minutes >= floor && minutes < limit }.first(share)
      floor = limit
      band
    end
    # Bands without enough tiles leave room for more of the quickest.
    picked += (tiles - picked).first(MAX_TILES - picked.size)
    picked.sort_by { |tile, minutes| [minutes, tile] }.map { |(row, column), _| [row * TILE_DEGREES, column * TILE_DEGREES] }
  end

  def self.tile_index(degrees)
    (degrees / TILE_DEGREES).floor
  end

  # The routes in the tiles, as { id:, name:, latitude:, longitude:, bounds:,
  # span:, notable: } with each route's [south, west, north, east] bounding box,
  # its center, and its diagonal in meters. Each tile's routes are cached, and
  # uncached tiles are queried TILES_PER_QUERY neighbors at a time, each query
  # finding the routes of the region around its tiles once, then keeping those
  # in the tiles, while tiles another search is querying are waited for. The
  # routes of tiles whose query fails are left out, unless every tile's do, and
  # each such failure is added to failures when given.
  def self.routes_in(tiles, connections: nil, cache: Rails.cache, failures: nil)
    keys = tiles.to_h { |tile| [tile, "overpass:tile:v1:#{tile.join(':')}"] }
    found = keys.empty? ? {} : cache.read_multi(*keys.values)
    missing = tiles.reject { |tile| found.key?(keys[tile]) }
    tile_of = keys.invert
    error = nil
    missing.sort.each_slice(TILES_PER_QUERY).with_index do |group, index|
      group_keys = group.map { |tile| keys[tile] }
      # Another search may have found some of them since this one began.
      found.merge!(cache.read_multi(*group_keys)) if index.positive?
      group_keys.reject! { |key| found.key?(key) }
      next if group_keys.empty?

      found.merge!(shared(group_keys, cache) do |own|
        own_tiles = own.map { |key| tile_of[key] }
        routes = elements(tiles_query(own_tiles), connections, cache, timeout: LONG_QUERY_SECONDS)
          .filter_map { |element| candidate(element) }
        own_tiles.to_h do |south, west|
          in_tile = routes.select do |route|
            route[:bounds][0] < south + TILE_DEGREES && route[:bounds][2] >= south &&
              route[:bounds][1] < west + TILE_DEGREES && route[:bounds][3] >= west
          end
          cache.write(keys[[south, west]], in_tile, expires_in: TILE_CACHE_TTL)
          [keys[[south, west]], in_tile]
        end
      rescue SearchErrors::UpstreamError => failure
        error ||= failure
        failures&.push(failure)
        {}
      end)
    end
    # Tiles another search was looking up, but couldn't in time, are left out too.
    if error.nil? && missing.any? { |tile| !found.key?(keys[tile]) }
      error = SearchErrors::ProviderBusy.new(BUSY)
      failures&.push(error)
    end
    raise error if error && keys.values.none? { |key| found.key?(key) }

    keys.values.filter_map { |key| found[key] }.flatten(1).uniq { |route| route[:id] }
  end

  # The values the block finds for keys, as { key => value }, shared with
  # other searches in this process: the block is given the keys no other
  # search is looking up, and returns what it found for them, and then those
  # another search is looking up are waited for, at most SHARED_WAIT_SECONDS,
  # and read from the cache when that search stored them without saying so in
  # time. Keys whose lookup fails or takes longer are left out.
  def self.shared(keys, cache)
    keys = keys.uniq
    mine = Concurrent::Promises.resolvable_future
    others = keys.filter_map { |key| (other = LOOKING_UP.put_if_absent(key, mine)) && [key, other] }.to_h
    own = keys - others.keys
    found = {}
    begin
      found = yield(own).to_h if own.any?
    ensure
      own.each { |key| LOOKING_UP.delete_pair(key, mine) }
      mine.fulfill(found)
    end
    return found if others.empty?

    TrailsService.settle(others.values.uniq, timeout: SHARED_WAIT_SECONDS)
    others.each do |key, other|
      value = other.value(0) if other.fulfilled?
      found[key] = value[key] if value&.key?(key)
    end
    late = others.keys.reject { |key| found.key?(key) }
    late.any? ? found.merge(cache.read_multi(*late)) : found
  end

  def self.tiles_query(tiles)
    region = [tiles.map(&:first).min, tiles.map(&:last).min,
      tiles.map(&:first).max + TILE_DEGREES, tiles.map(&:last).max + TILE_DEGREES]
    clauses = tiles.map { |south, west| "relation.region(#{south},#{west},#{south + TILE_DEGREES},#{west + TILE_DEGREES});" }
    %([out:json][timeout:40];relation["type"="route"]["route"="hiking"](#{region.join(',')})->.region;) +
      "(#{clauses.join});out tags bb;"
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

  # Up to MAX_TRANSIT_ROUTES ids of the routes transit may reach, most promising
  # and quickest first, keeping each trail's quickest section. relief is how
  # far the land rises around routes, in meters by id, as ElevationService.reliefs finds.
  def self.pick(candidates, access:, relief: {})
    reachable = candidates.filter_map { |route| (minutes = access.reach(route[:bounds])) && route.merge(minutes: minutes) }
    distinct(reachable.sort_by { |route| route[:minutes] })
      .sort_by { |route| [-promise(route, relief[route[:id]]), route[:minutes]] }.first(MAX_TRANSIT_ROUTES).pluck(:id)
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

  # Notable routes of day-hike size with distinct names are likelier to be good
  # hikes, and like TrailsService.score, routes across hills and mountains
  # likelier to be scenic, and long trips there count against routes. Without
  # these, an area with many notable routes would fill every check, however far.
  def self.promise(route, relief = nil)
    hours = route[:minutes].to_f * 2 / 60
    (route[:notable] ? 1 : 0) + (route[:span] >= 800 ? 0.5 : 0) - (generic_name?(route[:name]) ? 1 : 0) +
      [relief.to_i / 100.0, 4].min * TrailsService::SCENIC_WEIGHT - TrailsService.travel_penalty(hours)
  end

  def self.generic_name?(name)
    name.nil? || name == UNNAMED || name.match?(GENERIC_NAME)
  end

  # Trails for the route ids, in order. Each route's details are cached, and
  # only uncached routes are queried, once for searches that need them at
  # once. Raises when some can't be looked up.
  def self.routes(ids, connections, cache)
    return [] if ids.empty?

    keys = ids.to_h { |id| [id, "overpass:route:v2:#{id}"] }
    found = cache.read_multi(*keys.values)
    missing = ids.reject { |id| found.key?(keys[id]) }
    if missing.any?
      id_of = keys.invert
      found.merge!(shared(missing.map { |id| keys[id] }, cache) do |own|
        own_ids = own.map { |key| id_of[key] }
        fetched = fetch_routes(own_ids, connections, cache)
        own_ids.to_h do |id|
          # Routes that cannot be measured are remembered too, so they are not queried again.
          cache.write(keys[id], fetched.fetch(id, false), expires_in: ROUTE_CACHE_TTL)
          [keys[id], fetched.fetch(id, false)]
        end
      end)
      # Routes another search was looking up, but couldn't in time.
      raise SearchErrors::ProviderBusy, BUSY unless missing.all? { |id| found.key?(keys[id]) }
    end
    ids.filter_map { |id| Trail.new(**found[keys[id]]) if found[keys[id]] }
  end

  # Plain route attributes by id, never transit results, using the ids of each route's paved ways.
  def self.fetch_routes(ids, connections, cache)
    paved = PAVED_WAYS.map { |filter| "way.ways#{filter};" }
    query = "[out:json][timeout:40];relation(id:#{ids.join(',')})->.routes;.routes out geom;" \
      "way(r.routes)->.ways;(#{paved.join});out ids;"
    elements = elements(query, connections, cache, timeout: LONG_QUERY_SECONDS)
      .group_by { |element| element["type"] if element.is_a?(Hash) }
    paved = elements.fetch("way", []).pluck("id").to_set
    elements.except("way").values.flatten(1).each_with_object({}) do |element, routes|
      route = route_attributes(element, paved)
      routes[route[:osm_id]] = route if route
    end
  end

  # Highlights near each trail, as { osm_id => [{ kind:, name:, notable:, height: }] }
  # without the attributes they don't have: waterfalls first, then famous and
  # named ones before the others. notable is true for highlights with a Wikipedia
  # article, and height is a waterfall's in meters. Each route's list is cached,
  # and only uncached routes are queried.
  def self.highlights(trails, connections: nil, cache: Rails.cache)
    return {} if trails.empty?

    keys = trails.to_h { |trail| [trail.osm_id, "overpass:highlights:v3:#{trail.osm_id}"] }
    found = cache.read_multi(*keys.values)
    missing = trails.reject { |trail| found.key?(keys[trail.osm_id]) }
    if missing.any?
      filters = HIGHLIGHT_TAGS.values.map { |key, value| %(node(around.ways:#{HIGHLIGHT_METERS})["#{key}"="#{value}"];) }
      query = "[out:json][timeout:20];relation(id:#{missing.map(&:osm_id).join(',')});way(r)->.ways;(#{filters.join});out;"
      connections ||= [SearchHttp.connection(urls(cache).first, timeout: HIGHLIGHT_TIMEOUT_SECONDS)]
      points = elements(query, connections, cache, wait: 0).filter_map { |element| highlight_point(element) }
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
    return unless kind

    # A Wikipedia article, rather than only a Wikidata item, which every named hill has, marks a famous one.
    { kind: kind, name: name(tags)&.truncate(60), latitude: node["lat"], longitude: node["lon"],
      notable: tags["wikipedia"].is_a?(String) && tags["wikipedia"].strip.present?, height: (meters(tags["height"]) if kind == "waterfall") }
  end

  # A height such as "25", "25 m", or "80 ft" in meters, or nil.
  def self.meters(value)
    number = Float(value[/\A\s*(\d+(?:\.\d+)?)/, 1], exception: false) if value.is_a?(String)
    return unless number&.positive? && number < 1_000

    value.match?(/ft|'/i) ? (number * 0.3048).round(1) : number
  end

  def self.highlights_near(path, points)
    boxes = path.map { |line| bounding_box(line) }
    points.select { |point| path.each_with_index.any? { |line, index| near_line?(point, line, boxes[index]) } }
      .uniq { |point| [point[:kind], point[:name] || [point[:latitude], point[:longitude]]] }
      .sort_by { |point| [HIGHLIGHT_TAGS.keys.index(point[:kind]), point[:notable] ? 0 : 1, point[:name] ? 0 : 1] }
      .first(MAX_HIGHLIGHTS).map { |point| point.slice(:kind, :name, :notable, :height).compact_blank }
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

  # The response's elements, from the preferred instance or else the other one,
  # once one of the process's query slots is free, waiting at most wait seconds.
  # Lookups that don't wait for a slot aren't retried either.
  def self.elements(query, connections, cache, wait: SLOT_WAIT_SECONDS, timeout: 25)
    slots = Rails.configuration.x.overpass_slots
    raise SearchErrors::ProviderBusy, BUSY unless slots.try_acquire(1, wait)

    begin
      connections ||= urls(cache).map { |url| SearchHttp.connection(url, timeout: timeout) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        connections.each_with_index do |connection, index|
          return request(connection, query)
        rescue SearchErrors::UpstreamError
          cache.write(FAILOVER_KEY, !cache.read(FAILOVER_KEY), expires_in: FAILOVER_TTL) if index.zero?
          raise if index == connections.size - 1
        end
      rescue SearchErrors::ResponseTooLarge
        raise
      rescue SearchErrors::UpstreamError
        raise if wait.zero? || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > QUICK_FAILURE_SECONDS

        sleep Rails.configuration.x.overpass_retry_pause_seconds
        request(connections.first, query)
      end
    ensure
      slots.release
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

  def self.distance(lat1, lon1, lat2, lon2)
    radians = Math::PI / 180
    a = Math.sin((lat2 - lat1) * radians / 2)**2 +
      Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin((lon2 - lon1) * radians / 2)**2
    6_371_000 * 2 * Math.asin(Math.sqrt(a.clamp(0, 1)))
  end
end
