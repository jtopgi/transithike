require "faraday"
require "zlib"

module SearchTestSupport
  # body may be a lambda that builds the response body from the request.
  def stub_connection(method, body, status: 200, &assert_request)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.public_send(method, "/") do |request|
        assert_request&.call(request)
        payload = body.respond_to?(:call) ? body.call(request) : body
        [status, { "Content-Type" => "application/json" }, payload.is_a?(String) ? payload : JSON.generate(payload)]
      end
    end
    Faraday.new { |builder| builder.adapter :test, stubs }
  end

  # A straight route about 1.38 miles long, north from latitude.
  def route_element(id: 123, latitude: 47.0, name: "Forest Loop")
    {
      "type" => "relation", "id" => id,
      "tags" => { "type" => "route", "route" => "hiking", "name" => name, "description" => "A wooded walk" },
      "members" => [
        { "type" => "way", "ref" => id, "role" => "",
          "geometry" => [{ "lat" => latitude, "lon" => -122.0 }, { "lat" => latitude + 0.02, "lon" => -122.0 }] }
      ]
    }
  end

  def highlight_node(kind, latitude, longitude, name: nil, id: rand(1..1_000_000))
    key, value = OverpassService::HIGHLIGHT_TAGS.fetch(kind)
    { "type" => "node", "id" => id, "lat" => latitude, "lon" => longitude, "tags" => { key => value, "name" => name }.compact }
  end

  # The tiles, route details, or highlights response for an Overpass query,
  # built from full route elements.
  def overpass_elements(query, routes:, highlights: [], paved: [])
    if query.include?("out tags bb")
      routes.map { |route| candidate_of(route) }
    elsif query.include?("out geom")
      routes + paved.map { |id| { "type" => "way", "id" => id } }
    else
      highlights
    end
  end

  # A one-to-all entry: a stop served by modes, reached after minutes and rides.
  def reached_stop(latitude, longitude, minutes, rides: 1, modes: ["REGIONAL_RAIL"], id: nil, importance: nil)
    { "place" => { "lat" => latitude, "lon" => longitude, "modes" => modes, "stopId" => id, "importance" => importance }.compact,
      "duration" => minutes, "k" => rides }
  end

  def overpass_connection(routes: [route_element], queries: nil, **elements)
    stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries&.push(query)
      { "elements" => overpass_elements(query, routes: routes, **elements) }
    })
  end

  # A Terrarium elevation tile whose pixel at [column, row] is height.(column, row)
  # meters up, its rows filtered by each of PNG's five filters in turn.
  def terrarium_png(pixels: 256, header: nil, &height)
    previous = Array.new(pixels * 3, 0)
    rows = (0...pixels).map do |row|
      line = (0...pixels).flat_map do |column|
        value = height.(column, row) + 32_768
        [value.floor / 256, value.floor % 256, ((value % 1) * 256).floor]
      end
      filter = row % 5
      filtered = line.each_index.map do |index|
        left, up = index >= 3 ? line[index - 3] : 0, previous[index]
        corner = index >= 3 ? previous[index - 3] : 0
        predictor = case filter
        when 0 then 0
        when 1 then left
        when 2 then up
        when 3 then (left + up) / 2
        else paeth(left, up, corner)
        end
        (line[index] - predictor) & 255
      end
      previous = line
      [filter, *filtered].pack("C*")
    end
    "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", header || [pixels, pixels, 8, 2, 0, 0, 0].pack("NNC5")) +
      png_chunk("IDAT", Zlib::Deflate.deflate(rows.join)) + png_chunk("IEND", "")
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type + data)].pack("N")
  end

  def paeth(left, up, corner)
    guess = left + up - corner
    distances = [left, up, corner].map { |value| (guess - value).abs }
    [left, up, corner][distances.index(distances.min)]
  end

  # The elevation tile at a ".../zoom/x/y.png" path, with heights given by each pixel's latitude.
  def terrain_tile(path)
    zoom, x, y = path.scan(/\d+/).last(3).map(&:to_i)
    latitudes = (0...256).map do |row|
      Math.atan(Math.sinh(Math::PI * (1 - 2 * (y + (row + 0.5) / 256) / 2**zoom))) * 180 / Math::PI
    end
    terrarium_png { |_column, row| yield latitudes[row] }
  end

  # A route as the tiles query lists it: tags and a bounding box.
  def candidate_of(route)
    points = route["members"].flat_map { |member| member.is_a?(Hash) && member["geometry"].is_a?(Array) ? member["geometry"] : [] }
      .select { |point| point.is_a?(Hash) }
    route = route.slice("type", "id", "tags")
    return route if points.empty?

    latitudes, longitudes = points.map { |point| point["lat"] }, points.map { |point| point["lon"] }
    route.merge("bounds" => { "minlat" => latitudes.min, "minlon" => longitudes.min,
      "maxlat" => latitudes.max, "maxlon" => longitudes.max })
  end
end
