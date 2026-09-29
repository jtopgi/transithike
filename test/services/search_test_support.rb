require "faraday"

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

  def route_element(id: 123, latitude: 47.0, name: "Forest Loop")
    {
      "type" => "relation", "id" => id,
      "tags" => { "type" => "route", "route" => "hiking", "name" => name, "description" => "A wooded walk" },
      "members" => [
        { "type" => "way", "ref" => id, "role" => "",
          "geometry" => [{ "lat" => latitude, "lon" => -122.0 }, { "lat" => latitude + 0.01, "lon" => -122.0 }] }
      ]
    }
  end

  def highlight_node(kind, latitude, longitude, name: nil, id: rand(1..1_000_000))
    key, value = OverpassService::HIGHLIGHT_TAGS.fetch(kind)
    { "type" => "node", "id" => id, "lat" => latitude, "lon" => longitude, "tags" => { key => value, "name" => name }.compact }
  end

  # The area, route details or highlights response for an Overpass query, built
  # from full route elements.
  def overpass_elements(query, routes:, highlights: [], paved: [])
    if query.include?("out tags bb")
      routes.map { |route| candidate_of(route) }
    elsif query.include?("out geom")
      routes + paved.map { |id| { "type" => "way", "id" => id } }
    else
      highlights
    end
  end

  def overpass_connection(routes: [route_element], highlights: [], paved: [], queries: nil)
    stub_connection(:post, lambda { |request|
      query = URI.decode_www_form(request.body).to_h.fetch("data")
      queries&.push(query)
      { "elements" => overpass_elements(query, routes: routes, highlights: highlights, paved: paved) }
    })
  end

  # A route as the area query lists it: tags and a bounding box.
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
