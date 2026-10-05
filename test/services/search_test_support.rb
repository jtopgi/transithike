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
    lines = (0...pixels).map do |row|
      (0...pixels).flat_map do |column|
        value = height.(column, row) + 32_768
        [value.floor / 256, value.floor % 256, ((value % 1) * 256).floor]
      end
    end
    "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", header || [pixels, pixels, 8, 2, 0, 0, 0].pack("NNC5")) +
      png_chunk("IDAT", Zlib::Deflate.deflate(filtered_rows(lines, 3))) + png_chunk("IEND", "")
  end

  # The noise map's colors for its levels from 45 dB, and clear.
  NOISE_COLORS = { 45 => [255, 193, 7], 50 => [255, 128, 0], 55 => [255, 0, 0], 60 => [255, 51, 153], 70 => [163, 0, 204],
    80 => [82, 0, 204], 90 => [0, 0, 255] }.freeze

  # A noise map tile whose pixel at [column, row] is drawn for level.(column, row)
  # decibels from NOISE_COLORS, or clear for nil, in a palette with clear first,
  # its rows filtered by each of PNG's five filters in turn. extra adds colors
  # to the palette, as [red, green, blue] for level.(column, row) to give.
  def noise_png(extra: [], header: nil, &level)
    palette = [[253, 253, 253], *NOISE_COLORS.values, *extra]
    index = { nil => 0, **NOISE_COLORS.keys.each_with_index.to_h { |decibels, position| [decibels, position + 1] },
      **extra.each_with_index.to_h { |color, position| [color, NOISE_COLORS.size + 1 + position] } }
    lines = (0...256).map { |row| (0...256).map { |column| index.fetch(level.(column, row)) } }
    "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", header || [256, 256, 8, 3, 0, 0, 0].pack("NNC5")) +
      png_chunk("PLTE", palette.flatten.pack("C*")) + png_chunk("tRNS", [0].pack("C")) +
      png_chunk("IDAT", Zlib::Deflate.deflate(filtered_rows(lines, 1))) + png_chunk("IEND", "")
  end

  # Rows of bytes, bytes_per_pixel to a pixel, filtered by each of PNG's five filters in turn.
  def filtered_rows(lines, bytes_per_pixel)
    previous = Array.new(lines.first.size, 0)
    lines.each_with_index.map do |line, row|
      filter = row % 5
      filtered = line.each_index.map do |index|
        left = index >= bytes_per_pixel ? line[index - bytes_per_pixel] : 0
        up, corner = previous[index], index >= bytes_per_pixel ? previous[index - bytes_per_pixel] : 0
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
    end.join
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type + data)].pack("N")
  end

  def paeth(left, up, corner)
    guess = left + up - corner
    distances = [left, up, corner].map { |value| (guess - value).abs }
    [left, up, corner][distances.index(distances.min)]
  end

  # The noise map tile at a ".../zoom/y/x" path, with the level given by each
  # pixel's latitude, in decibels from NOISE_COLORS, or nil for clear.
  def noise_tile(path)
    zoom, y = path.scan(/\d+/).last(3).first(2).map(&:to_i)
    latitudes = (0...256).map do |row|
      Math.atan(Math.sinh(Math::PI * (1 - 2 * (y + (row + 0.5) / 256) / 2**zoom))) * 180 / Math::PI
    end
    noise_png { |_column, row| yield latitudes[row] }
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
