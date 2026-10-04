require "test_helper"
require_relative "../services/search_test_support"

class SearchesIntegrationTest < ActionDispatch::IntegrationTest
  include SearchTestSupport

  setup do
    # 3 PM on Tuesday in Seattle, so trips are for 8 AM on Saturday.
    travel_to Time.utc(2026, 9, 22, 22)
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    @stubs = Faraday::Adapter::Test::Stubs.new
    stubs = @stubs
    Faraday.default_adapter = Class.new(Faraday::Adapter::Test) do
      define_method(:initialize) { |app| super(app, stubs) }
    end
    Faraday.default_adapter_options = {}
    @requests = Hash.new { |requests, path| requests[path] = [] }
    ElevationService::TILES.clear
  end

  teardown do
    Faraday.default_adapter = @old_adapter
    Faraday.default_adapter_options = @old_adapter_options
    travel_back
  end

  def stub_get(url, body = nil, status: 200, &block)
    path = URI(url).path
    @stubs.get(path) do |env|
      @requests[path] << env
      block ? block.call(env) : [status, {}, body.is_a?(String) ? body : JSON.generate(body)]
    end
  end

  # Photon names where points are: Mount Vernon north of 48°, Seattle north of 47.5°, and Auburn south of it.
  def localities
    stub_get(PhotonService::REVERSE_URL) do |env|
      latitude = Float(env.params["lat"])
      city = latitude >= 48 ? "Mount Vernon" : latitude >= 47.5 ? "Seattle" : "Auburn"
      [200, {}, JSON.generate(features: [{ properties: { city: city, state: "Washington", country: "United States" } }])]
    end
  end

  def geocode(features = [{ geometry: { coordinates: [-122, 47] },
    properties: { name: "Seattle", state: "Washington", country: "United States" } }])
    stub_get(PhotonService::URL, { features: features })
  end

  def area(time_zone: "America/Los_Angeles")
    stub_get(TransitousService::REVERSE_GEOCODE_URL, [{ tz: time_zone, areas: [{ name: "Seattle", default: true }] }])
  end

  # Transit reaches a station a kilometer from the origin at 47, -122 in ten
  # minutes, and trains from there reach the stations, [latitude, longitude,
  # minutes] from the origin. By default, one 33 km north.
  def rail(stations = [[47.3, -122.0, 50]])
    stub_get(TransitousService::ONE_TO_ALL_URL) do |env|
      all = if env.params["transitModes"]
        stations.map { |latitude, longitude, minutes| reached_stop(latitude, longitude, minutes - 10) }
      else
        [reached_stop(47.01, -122.0, 10, id: "hub", importance: 0.5)]
      end
      [200, {}, JSON.generate(all: all)]
    end
  end

  # Both Overpass instances answer the tiles, route details and highlights queries.
  def hiking(routes, highlights: [], paved: [])
    OverpassService::URLS.each do |url|
      @stubs.post(URI(url).path) do |env|
        query = URI.decode_www_form(env.body).to_h.fetch("data")
        @requests["overpass"] << query
        [200, {}, JSON.generate(elements: overpass_elements(query, routes: routes, highlights: highlights, paved: paved))]
      end
    end
  end

  # The one-request API answers trips there; with arriveBy, the latest trips
  # back from each route and each linear route's far end, which by default leave
  # two hours before the 11 PM deadline, and returns stand for the first ones
  # asked about, the rest having none; and with transitModes, trips by city
  # transit, which by default reach nothing.
  def transit(trips, returns: nil, city: nil, walks: [])
    stub_get(TransitousService::ONE_TO_MANY_URL) do |env|
      back = env.params["arriveBy"] == "true"
      asked = env.params["many"].split(",").size
      durations = if back
        returns ? returns + Array.new(asked - returns.size) { [] } : Array.new(asked) { [{ duration: 7200, transfers: 0 }] }
      elsif env.params["transitModes"]
        city || trips.map { [] }
      else
        trips
      end
      [200, {}, JSON.generate(transit_durations: durations, street_durations: back || env.params["transitModes"] ? [] : walks)]
    end
  end

  # Elevation tiles with heights by latitude, by default flat land 50 m up.
  def elevation(height = ->(_latitude) { 50 })
    path = URI(ElevationService::TILE_URL).path
    @stubs.get(/\A#{Regexp.escape(path)}/) do |env|
      @requests[path] << env
      [200, {}, terrain_tile(env.url.path) { |latitude| height.(latitude) }]
    end
  end

  def search_all(params)
    get search_stream_path(params)
    assert_response :success
    assert_equal "text/event-stream", response.media_type
  end

  # The stream's events as [name, data] pairs.
  def events
    response.body.split("\n\n").map { |chunk| [chunk[/^event: (.+)$/, 1], JSON.parse(chunk[/^data: (.+)$/, 1])] }
  end

  def data_for(name)
    events.select { |event, _| event == name }.map(&:last)
  end

  # The cards from the stream's batches of hikes, as one document.
  def cards
    Nokogiri::HTML5.fragment(data_for("trails").map { |batch| batch["html"] }.join)
  end

  test "the home page asks for a starting point and a weekend day" do
    get root_path
    assert_response :success
    assert_equal %w[origin lat lon tz day day], css_select("form[action='#{search_path}'] [name]").map { |field| field["name"] }
    assert_select "input[name=origin][role=combobox][aria-controls=origin-suggestions][required]"
    assert_select "input[name=lat][disabled]"
    assert_select "input[name=day][value=saturday][checked]"
    assert_select "input[name=day][value=sunday]:not([checked])"
    assert_select "button[data-use-location][hidden]"
    assert_select "h1", text: "Weekend hikes you can reach by train"
  end

  test "the results page shows at once, ready to stream the search for the day asked for" do
    get search_path, params: { origin: "Pike Place Market", lat: "47.0", lon: "-122.0", day: "sunday", tz: "America/New_York" }

    assert_response :success
    assert_empty @requests
    assert_select "h1[data-heading]", text: "Day hikes by train from Pike Place Market"
    assert_select "[data-stream-url='#{search_stream_path(origin: 'Pike Place Market', lat: '47.0', lon: '-122.0',
      day: 'sunday', tz: 'America/New_York')}']"
    assert_select "input[name=lat][value='47.0']:not([disabled])"
    assert_select "input[name=tz][value='America/New_York']"
    assert_select "input[name=day][value=sunday][checked]"
    assert_select "[data-progress][role=status]", text: /Finding the stations trains reach/
    assert_select "[data-skeleton]", count: 2
    # Hikes are only ever most scenic first, the sliders narrowing them down.
    assert_select "[data-results-toolbar][hidden]"
    assert_select "select", count: 0
    # Sliders at their ends filter nothing: a round trip of 2 to 8 hours, and lengths from 1 to 20 miles.
    assert_select "[data-results-toolbar] input[type=range][data-max-trip][min='120'][max='480'][value='480']"
    assert_select "[data-length-range] input[type=range][data-length-min][min='1'][max='20'][value='1']"
    assert_select "[data-length-range] input[type=range][data-length-max][min='1'][max='20'][value='20']"
    assert_select "footer a[href='#{ElevationService::ATTRIBUTION_URL}']", text: "Terrain Tiles"
    assert_select "noscript", text: /needs JavaScript/
    assert_select "footer a[href='https://transitous.org/sources/']", text: "data sources"
    assert_includes response.body, "a way back by 11 PM"
    assert_includes response.body, "at least 20 km"

    get search_path, params: { origin: "Seattle", day: "monday", tz: "Not a zone" }
    assert_select "[data-stream-url='#{search_stream_path(origin: 'Seattle')}']"
    assert_select "input[name=tz][value]", count: 0
    assert_select "input[name=day][value=saturday][checked]"
  end

  test "a typed place streams the place, each batch of hikes by train with the way back, and the ranking" do
    geocode
    area
    rail
    hiking([route_element(latitude: 47.3, name: "<script>alert(1)</script>")])
    transit([[{ duration: 5400, transfers: 1 }]])
    elevation
    search_all(origin: "A & B / 東京", tz: "America/Los_Angeles")

    assert_equal %w[place checking trails ranking update done], events.map(&:first)
    # The visitor's time zone ranks places near them first.
    assert_equal ["A & B / 東京", "34.1", "-118.2"], @requests["/api/"].first.params.values_at("q", "lat", "lon")
    hubs, rides = @requests[URI(TransitousService::ONE_TO_ALL_URL).path].map(&:params)
    assert_equal ["47.0000000,-122.0000000", "2026-09-26T15:00:00Z", "60"], hubs.values_at("one", "time", "maxTravelTime")
    assert_equal ["hub", "2026-09-26T15:10:00Z", TransitousService::TRAIN_MODES.join(",")],
      rides.values_at("one", "time", "transitModes")
    trips, city, returns = @requests[URI(TransitousService::ONE_TO_MANY_URL).path].map(&:params)
    assert_equal ["47.0000000;-122.0000000", "47.3000000;-122.0000000", "2026-09-26T15:00:00Z", nil],
      trips.values_at("one", "many", "time", "transitModes")
    assert_equal ["47.3000000;-122.0000000", "SUBWAY,TRAM"], city.values_at("many", "transitModes")
    # The last trips back from the route, and from its far end.
    assert_equal ["47.3000000;-122.0000000,47.3200000;-122.0000000", "2026-09-27T06:00:00Z", "true"],
      returns.values_at("many", "time", "arriveBy")
    # The station is on the line between two tiles, so routes within a walk of it are in either.
    assert_includes @requests["overpass"].first, 'relation["type"="route"]["route"="hiking"](47.0,-122.5,47.5,-121.5)->.region;'

    place = data_for("place").sole
    assert_equal "Day hikes by train from Seattle, Washington, United States", place["heading"]
    assert_equal "Saturday, September 26, leaving at 8:00\u00a0AM\u00a0PDT, with a way back by 11\u00a0PM.", place["departure"]
    assert_equal "America/Los_Angeles", place["time_zone"]
    assert_equal [{ "count" => 1 }], data_for("checking")

    # Coming back the same way takes as long as going until the card's trips are planned. The route is hiked out and
    # back, 2.76 miles in 1½ hours at least, and the last trip back leaves half an hour after.
    card = cards.at_css("[data-trail][data-osm-id='123'][data-travel='10800'][data-length='2.76'][data-scenic='0.0']" \
      "[data-required='7200'][data-plan='out_and_back']")
    assert card
    # Arriving at 9:30 AM with the last trip back at 9 PM leaves 11 hours 30 minutes.
    assert_equal "· up to 11 h there", card.at_css("[data-stay-label]").text.squish
    assert card.at_css(".trail-map[data-path='[[[47.3,-122.0],[47.32,-122.0]]]'][data-start='[47.3,-122.0]']")
    # Photos are looked for at the route's middle and a sixth of the way from each end.
    assert card.at_css("a[data-photos-url='#{photos_path(points: '47.32,-122.0|47.3,-122.0')}'][hidden]")
    assert card.at_css("[data-gallery][hidden]")
    # The climb shows once the search has looked up the route's terrain.
    assert card.at_css("[data-climb-stat][hidden]")
    assert_nil card.at_css("[data-distance]")
    assert_match(/Round trip\s+≈ 3 h\s+≈ 1 h 30 min each way · 1 transfer/, card.at_css(".trail-stats").text.squish)
    assert_match(/Hike ≈ 2.8 mi out and back/, card.at_css(".trail-stats").text.squish)
    assert_match(/Last trip back 9:00 PM\s+· up to 11 h there/, card.at_css(".trail-return").text.squish)
    trip_url = card.at_css("[data-trip-url]")["data-trip-url"]
    # The way back is planned from after the 2 hours the search requires for hiking.
    assert_equal trip_path(from: "47.0,-122.0", to: "47.3,-122.0", leave: "2026-09-26T15:00:00Z", back_by: "2026-09-27T06:00:00Z",
      hike: 120), trip_url
    assert_equal hike_path(route: 123, plan: "out_and_back", from: "47.0,-122.0", to: "47.3,-122.0", leave: "2026-09-26T15:00:00Z",
      back_by: "2026-09-27T06:00:00Z", tz: "America/Los_Angeles", origin: "Seattle, Washington, United States"),
      card.at_css("a[href^='/hike?']")["href"]
    assert_nil card.at_css("[data-finish]")
    assert_equal ["🧭 Directions"], card.css("a[href^='https://www.google.com/maps/dir/']").map(&:text)
    assert card.at_css("a[href='https://www.openstreetmap.org/relation/123'][target=_blank]")
    query = URI.decode_www_form(URI(card.at_css("a[href^='https://www.google.com/maps/dir/?']")["href"]).query).to_h
    assert_equal ["Seattle, Washington, United States", "47.3,-122.0", "transit"], query.values_at("origin", "destination", "travelmode")
    assert_nil card.at_css("script")
    assert_includes card.to_html, "&lt;script&gt;"

    update = data_for("update").sole["trails"].sole
    # Flat land has no views, and nothing to climb.
    assert_equal [123, 0.0, "≈ 0 ft"], update.values_at("id", "scenic", "climb")
    assert_nil update["popularity"]
    assert_kind_of Numeric, update["score"]
    assert_equal({ "count" => 1, "notices" => [] }, data_for("done").sole)
  end

  test "a search for Sunday sets out on Sunday morning" do
    geocode
    area
    rail
    hiking([])
    search_all(origin: "Seattle", day: "sunday")
    assert_equal "Sunday, September 27, leaving at 8:00\u00a0AM\u00a0PDT, with a way back by 11\u00a0PM.",
      data_for("place").sole["departure"]
    assert_equal "2026-09-27T15:00:00Z", @requests[URI(TransitousService::ONE_TO_ALL_URL).path].first.params["time"]
  end

  test "hikes are joined where the train reaches them soonest, then ranked with highlights and terrain" do
    area
    rail([[47.32, -122.001, 50]])
    route = route_element(latitude: 47.3, name: "Falls Loop")
    hiking([route], highlights: [highlight_node("waterfall", 47.305, -122.0005, name: "Twin Falls")])
    transit([[{ duration: 2400, transfers: 1 }]])
    # The land rises in steps 400 m along the route, whose top stands 362 m above the land 2 km south of it.
    elevation(->(latitude) { latitude < 47.301 ? 0 : latitude < 47.31 ? 38 : 400 })
    search_all(origin: "Pike Place Market", lat: "47.0", lon: "-122.0")

    assert_empty @requests["/api/"]
    assert_equal "Day hikes by train from Pike Place Market", data_for("place").sole["heading"]
    assert_equal "47.3200000;-122.0000000", @requests[URI(TransitousService::ONE_TO_MANY_URL).path].first.params["many"]
    card = cards.at_css("[data-trail]")
    assert card.at_css(".trail-map[data-start='[47.32,-122.0]']")
    query = URI.decode_www_form(URI(card.at_css("a[href^='https://www.google.com/maps/dir/?']")["href"]).query).to_h
    assert_equal "47.32,-122.0", query["destination"]

    update = data_for("update").sole["trails"].sole
    # Four points for views, and half of two for the waterfall.
    assert_equal [5.0, "≈ 1,300 ft"], update.values_at("scenic", "climb")
    chips = Nokogiri::HTML5.fragment(update["chips"])
    assert chips.at_css(".trail-chip[title='Its high point stands about 1,200 ft above the land within about a mile, " \
      "and it climbs about 1,300 ft']")
    assert chips.at_css(".trail-chip[title='Waterfall: Twin Falls']")
    assert_equal ["Big views", "Twin Falls"], chips.css(".trail-chip-label").map(&:text)
  end

  test "hikes the subway or light rail reaches, and stations near the city, are left out" do
    geocode
    area
    # A station 33 km north, and one 11 km south.
    rail([[47.3, -122.0, 50], [46.9, -122.0, 20]])
    hiking([route_element(latitude: 47.3)])
    transit([[{ duration: 5400, transfers: 1 }]], city: [[{ duration: 6000, transfers: 2 }]])
    search_all(origin: "Seattle")
    assert_equal %w[place checking done], events.map(&:first)
    assert_equal 0, data_for("done").sole["count"]
    assert_includes @requests["overpass"].first, "(47.0,-122.0,47.5,-121.5)"
    refute_includes @requests["overpass"].first, "(46.5,"
  end

  test "without stations beyond the city, no hikes are looked for" do
    geocode
    area
    rail([[46.9, -122.0, 20]])
    search_all(origin: "Seattle")
    assert_equal [["place", "done"], 0], [events.map(&:first), data_for("done").sole["count"]]
    assert_empty @requests["overpass"]
  end

  test "the device's location is named after its area and starts directions from it" do
    area
    rail
    hiking([route_element(latitude: 47.3)])
    transit([[{ duration: 4000, transfers: 0 }]])
    elevation
    search_all(origin: SearchesController::CURRENT_LOCATION, lat: "47.0", lon: "-122.0")

    assert_equal "Day hikes by train from your location in Seattle", data_for("place").sole["heading"]
    assert_match(/≈ 2 h 15 min\s+≈ 1 h 5 min each way · direct/, cards.at_css(".trail-stats").text.squish)
    href = cards.at_css("a[href^='https://www.google.com/maps/dir/?']")["href"]
    refute_includes URI.decode_www_form(URI(href).query).to_h, "origin"
  end

  test "invalid coordinates fall back to looking up the typed place" do
    geocode
    area
    rail
    hiking([])
    search_all(origin: "Seattle", lat: "91", lon: "-122.0")
    assert_equal 1, @requests["/api/"].size
    assert_equal({ "count" => 0, "notices" => [] }, data_for("done").sole)
  end

  test "trips fall back to planning each route when the one-request API fails, and say the way back wasn't checked" do
    geocode
    area
    rail
    hiking([route_element(latitude: 47.3)])
    stub_get(TransitousService::ONE_TO_MANY_URL, "not json")
    stub_get(TransitousService::PLAN_URL, { itineraries: [{ duration: 4800, transfers: 2 }], direct: [] })
    elevation
    search_all(origin: "Seattle")

    assert_match(/≈ 2 h 40 min\s+≈ 1 h 20 min each way · 2 transfers/, cards.at_css(".trail-stats").text.squish)
    assert_match(/couldn't check the way back/, cards.at_css(".trail-return").text)
    assert_equal ["We couldn't check the way back for some hikes. Check the last trip back before you go."],
      data_for("done").sole["notices"]
  end

  test "a failed area lookup still searches, in UTC" do
    geocode
    stub_get(TransitousService::REVERSE_GEOCODE_URL, "{}", status: 503)
    rail
    hiking([])
    search_all(origin: "Seattle")
    assert_equal "Saturday, September 26, leaving at 8:00\u00a0AM\u00a0UTC, with a way back by 11\u00a0PM.",
      data_for("place").sole["departure"]
  end

  test "hikes without a way back the same day are left out" do
    geocode
    area
    rail
    hiking([route_element(latitude: 47.3)])
    transit([[{ duration: 5400, transfers: 1 }]], returns: [[]])
    search_all(origin: "Seattle")
    assert_equal %w[place checking done], events.map(&:first)
    assert_equal 0, data_for("done").sole["count"]
  end

  test "invalid origins are rejected before external requests" do
    [nil, "", "   ", "a" * 201, ["Seattle"], { city: "Seattle" }].each do |origin|
      get search_path, params: { origin: origin }
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /Enter a starting point/
      assert_select "[data-stream-url]", count: 0

      search_all(origin: origin)
      assert_equal [["failure", { "message" => "Enter a starting point of at most 200 characters." }]], events
    end
    assert_empty @requests
  end

  test "an unknown place streams an actionable failure" do
    geocode([])
    search_all(origin: "Nowhere")
    assert_match(/could not find that starting point/, data_for("failure").sole["message"])
  end

  test "place search failures stream a safe failure" do
    stub_get(PhotonService::URL, '{"error":"private provider details"}', status: 503)
    search_all(origin: "Seattle")
    assert_match(/unavailable/, data_for("failure").sole["message"])
    refute_includes response.body, "private provider details"
  end

  test "a failed rail station lookup is a failure, not an empty success" do
    geocode
    area
    stub_get(TransitousService::ONE_TO_ALL_URL, "{}", status: 503)
    search_all(origin: "Seattle")
    assert_equal %w[place failure], events.map(&:first)
    assert_match(/unavailable/, data_for("failure").sole["message"])
  end

  test "a malformed route response is a failure, not an empty success" do
    geocode
    area
    rail
    OverpassService::URLS.each { |url| @stubs.post(URI(url).path) { [200, {}, "not json"] } }
    search_all(origin: "Seattle")
    assert_equal %w[place failure], events.map(&:first)
    assert_equal 2, @requests[URI(TransitousService::ONE_TO_ALL_URL).path].size
  end

  def leg(mode, name, start, finish, from: nil, to: nil)
    { mode: mode, routeShortName: name, agencyName: "Metro", headsign: "Downtown", startTime: start, endTime: finish,
      from: { stopId: from }.compact, to: { stopId: to }.compact }
  end

  def journey(start, finish, legs)
    { duration: (Time.iso8601(finish) - Time.iso8601(start)).to_i, transfers: 0, startTime: start, endTime: finish, legs: legs }
  end

  # The same trains back, leaving and arriving at these UTC times: in the
  # afternoon or evening of September 23, or early on September 24.
  def train_back(leave, home)
    leave, home = [leave, home].map { |time| "2026-09-#{time >= '12:00' ? 23 : 24}T#{time}:00Z" }
    journey(leave, home, [leg("REGIONAL_RAIL", "Cascades", leave, home, from: "mount-vernon", to: "seattle")])
  end

  test "a trip lists the trains there and the same trains back: home soonest after the hike, and the last ones" do
    stub_get(TransitousService::PLAN_URL) do |env|
      body = if env.params["arriveBy"] == "true"
        { itineraries: [train_back("20:00", "21:30"), train_back("21:00", "22:35"), train_back("23:00", "00:20"),
          train_back("03:30", "05:15")], direct: [] }
      else
        { itineraries: [journey("2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z", [
          leg("BUS", "7", "2026-09-23T15:19:00Z", "2026-09-23T15:30:00Z", from: "home-stop", to: "king-street"),
          leg("REGIONAL_RAIL", "Cascades", "2026-09-23T15:40:00Z", "2026-09-23T17:20:00Z", from: "seattle", to: "mount-vernon")
        ])], direct: [] }
      end
      [200, {}, JSON.generate(body)]
    end
    localities
    # Hiking for three hours after arriving at 5:31 PM UTC.
    get trip_path(from: "47.6,-122.3", to: "48.4,-122.3", leave: "2026-09-23T15:00:00Z", back_by: "2026-09-24T06:00:00Z", hike: "180")

    assert_response :success
    # Where the route is, without the country it shares with the starting point.
    assert_equal "Mount Vernon, Washington", response.parsed_body["location"]
    there, back, last, same_way = response.parsed_body.values_at("there", "back", "last", "same_way")
    assert_equal ["2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z"], there.values_at("departure", "arrival")
    assert_equal({ "mode" => "REGIONAL_RAIL", "name" => "Cascades", "agency" => "Metro", "headsign" => "Downtown" }, there["legs"].last)
    assert_equal ["2026-09-23T21:00:00Z", "2026-09-23T22:35:00Z"], back.values_at("departure", "arrival")
    assert_equal ["2026-09-24T03:30:00Z", "Cascades"], [last["departure"], last["legs"].sole["name"]]
    assert same_way
    there_request, back_request = @requests[URI(TransitousService::PLAN_URL).path].map(&:params)
    assert_equal ["47.6000000,-122.3000000", "48.4000000,-122.3000000", "false"], there_request.values_at("fromPlace", "toPlace", "arriveBy")
    assert_equal ["48.4000000,-122.3000000", "47.6000000,-122.3000000", "true", "2026-09-24T06:00:00Z"],
      back_request.values_at("fromPlace", "toPlace", "arriveBy", "time")
    # Back from the station the train stopped at to the one it started from, from the end of the hike on.
    assert_equal ["mount-vernon,seattle", "BUS,REGIONAL_RAIL,SUBWAY,TRAM", "34140"],
      back_request.values_at("via", "transitModes", "searchWindow")
    assert_equal "private", response.headers["Cache-Control"].split(", ").find { |part| part.start_with?("private") }
  end

  test "a trip back from a route's far end goes any way from there" do
    stub_get(TransitousService::PLAN_URL) do |env|
      body = if env.params["arriveBy"] == "true"
        { itineraries: [train_back("21:00", "22:35")], direct: [] }
      else
        { itineraries: [journey("2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z", [
          leg("REGIONAL_RAIL", "Cascades", "2026-09-23T15:40:00Z", "2026-09-23T17:20:00Z", from: "seattle", to: "mount-vernon")
        ])], direct: [] }
      end
      [200, {}, JSON.generate(body)]
    end
    get trip_path(from: "47.6,-122.3", to: "48.4,-122.3", finish: "48.5,-122.3", leave: "2026-09-23T15:00:00Z",
      back_by: "2026-09-24T06:00:00Z", hike: "180")

    assert_response :success
    assert_equal ["2026-09-23T21:00:00Z", nil], response.parsed_body["back"].values_at("departure") + [response.parsed_body["same_way"]]
    back_request = @requests[URI(TransitousService::PLAN_URL).path].last.params
    # By train, with the subway or light rail to reach it, unless none goes.
    assert_equal ["48.5000000,-122.3000000", nil, TransitousService::TRIP_MODES.join(",")],
      back_request.values_at("fromPlace", "via", "transitModes")
    get trip_path(from: "47.6,-122.3", to: "48.4,-122.3", finish: "nowhere", leave: "2026-09-23T15:00:00Z",
      back_by: "2026-09-24T06:00:00Z")
    assert_response :bad_request
  end

  # A train there from Seattle leaving and arriving at these UTC times on September 23, or early on September 24.
  def train_there(leave, arrive)
    leave, arrive = [leave, arrive].map { |time| "2026-09-#{time >= '12:00' ? 23 : 24}T#{time}:00Z" }
    journey(leave, arrive, [leg("REGIONAL_RAIL", "Cascades", leave, arrive, from: "seattle", to: "mount-vernon")
      .merge(from: { stopId: "seattle", name: "King Street" }, to: { stopId: "mount-vernon", name: "Mount Vernon" })])
  end

  # The planner answers a journey there, the trips there in a window, and the trips back.
  def planner(there: [train_there("15:19", "17:31")], window: [], back: [])
    stub_get(TransitousService::PLAN_URL) do |env|
      trips = if env.params["arriveBy"] == "true" then back
      elsif env.params["timetableView"] == "true" then window
      else there
      end
      [200, {}, JSON.generate(itineraries: trips, direct: [])]
    end
  end

  def hike_params(**changes)
    { route: 123, plan: "out_and_back", from: "47.6,-122.3", to: "47.3,-122.0", leave: "2026-09-23T15:00:00Z",
      back_by: "2026-09-24T06:00:00Z", tz: "America/Los_Angeles", origin: "Pike Place Market" }.merge(changes)
  end

  test "a hike's page shows its highlights when where it is takes too long to look up" do
    hiking([route_element(latitude: 47.3, name: "Ridge Trail")], highlights: [highlight_node("waterfall", 47.31, -122.0, name: "Twin Falls")])
    elevation
    stub_get(WikipediaService::API_URL, {})
    planner(window: [train_there("15:19", "17:31")], back: [train_back("20:00", "21:30")])
    stub_get(PhotonService::REVERSE_URL) do
      sleep 1.5
      [200, {}, JSON.generate(features: [{ properties: { city: "Auburn", state: "Washington" } }])]
    end
    stub_const(HikesController, :EXTRAS_WAIT_SECONDS, 1) { get hike_path(hike_params) }

    assert_response :success
    assert_select ".trail-chip", text: /Twin Falls/
    assert_select ".trail-location", count: 0
  end

    test "a hike's page shows its route, the trips there that leave time to hike all of it, and the trips back" do
    hiking([route_element(latitude: 47.3, name: "Ridge Trail")], highlights: [highlight_node("waterfall", 47.31, -122.0, name: "Twin Falls")])
    elevation
    stub_get(WikipediaService::API_URL, {})
    back = [train_back("20:00", "21:30"), train_back("21:00", "22:35"), train_back("03:30", "05:15")]
    back.each { |trip| trip[:legs].first[:from][:name] = "Mount Vernon" }
    planner(window: [train_there("15:19", "17:31"), train_there("16:19", "18:31"), train_there("23:19", "01:31")], back: back)
    localities
    get hike_path(hike_params)

    assert_response :success
    assert_select ".trail-location", "📍 Auburn, Washington"
    assert_select "meta[name=robots][content=noindex]"
    assert_select "h1", text: "Ridge Trail"
    assert_select "a[href='#{search_path(origin: 'Pike Place Market', lat: 47.6, lon: -122.3, day: 'sunday', tz: 'America/Los_Angeles')}']",
      text: "← All hikes from Pike Place Market"
    assert_select "[data-hike-map][data-path='[[[47.3,-122.0],[47.32,-122.0]]]'][data-start='[47.3,-122.0]']:not([data-finish])"
    assert_select ".trail-chip", text: /Twin Falls/
    facts = css_select(".hike-facts").sole.text.squish
    assert_match(/Hike ≈ 2.8 mi out and back, about 1 h 30 min/, facts)
    assert_match(/Last trip back 8:30 PM from Mount Vernon/, facts)
    assert_equal "Taking the first trip there, you arrive at 10:31 AM and have up to 9 h 59 min until the last trip back, " \
      "for a hike of about 1 h 30 min.", css_select(".hike-intro").sole.text.squish
    there, back = css_select("table.timetable tbody").map { |table| table.css("tr").map { |row| row.css("td").first(2).map(&:text) } }
    # Arriving at 6:31 PM leaves no time to hike before the last trip back.
    assert_equal [["8:19 AM", "10:31 AM"], ["9:19 AM", "11:31 AM"]], there
    assert_equal [["1:00 PM", "2:30 PM"], ["2:00 PM", "3:35 PM"], ["8:30 PM", "10:15 PM"]], back
    assert_select "tr.timetable-last", text: /8:30 PM.*Last/m
    assert_select "td", text: /Cascades from King Street to Mount Vernon/
    assert_equal ["🧭 Directions"], css_select("a[href^='https://www.google.com/maps/dir/']").map(&:text)
    departures = @requests[URI(TransitousService::PLAN_URL).path].map(&:params).find { |params| params["timetableView"] == "true" &&
      params["arriveBy"] == "false" }
    assert_equal ["47.6000000,-122.3000000", "47.3000000,-122.0000000"], departures.values_at("fromPlace", "toPlace")
  end

  test "a hike to the far end comes back any way from there, with directions back" do
    hiking([route_element(latitude: 47.3, name: "Ridge Trail")])
    elevation
    stub_get(WikipediaService::API_URL, {})
    planner(window: [train_there("15:19", "17:31")], back: [train_back("21:00", "22:35")])
    get hike_path(hike_params(plan: "through", finish: "47.32,-122.0"))

    assert_response :success
    assert_select "[data-hike-map][data-finish='[47.32,-122.0]']"
    assert_match(/Hike ≈ 1.4 mi one way, back from the far end/, css_select(".hike-facts").sole.text.squish)
    back_request = @requests[URI(TransitousService::PLAN_URL).path].map(&:params).find { |params| params["arriveBy"] == "true" }
    assert_equal ["47.3200000,-122.0000000", nil], back_request.values_at("fromPlace", "via")
    query = URI.decode_www_form(URI(css_select("a").find { |link| link.text == "🧭 Directions back" }["href"]).query).to_h
    assert_equal ["47.32,-122.0", "47.6,-122.3"], query.values_at("origin", "destination")
  end

  test "a hike's page needs a route, points, a plan, times on one day, and a time zone, and says when it can't plan" do
    [{ route: "abc" }, { plan: "wander" }, { plan: "through" }, { from: "91,0" }, { to: nil }, { tz: "Mars/Olympus" },
      { leave: "soon" }, { back_by: "2026-09-26T06:00:00Z" }].each do |change|
      get hike_path(hike_params(**change).compact)
      assert_response :bad_request
    end
    assert_empty @requests

    hiking([])
    get hike_path(hike_params)
    assert_response :not_found

    hiking([route_element(latitude: 47.3)])
    elevation
    stub_get(WikipediaService::API_URL, {})
    stub_get(TransitousService::PLAN_URL, "{}", status: 503)
    get hike_path(hike_params)
    assert_response :service_unavailable
    assert_select ".alert", text: /transit planner is unavailable/
  end

  test "trips need two points, times on one day, and hikes that fit between them, and provider failures say so" do
    valid = { from: "47.6,-122.3", to: "48.4,-122.3", leave: "2026-09-23T15:00:00Z", back_by: "2026-09-24T06:00:00Z" }
    [{ from: "91,0" }, { to: "north" }, { from: nil }, { leave: "tomorrow" }, { back_by: "2026-09-23T14:00:00Z" },
      { back_by: "2026-09-26T06:00:00Z" }, { leave: "2026-10-30T15:00:00Z", back_by: "2026-10-31T06:00:00Z" },
      { hike: "three hours" }, { hike: "-5" }, { hike: "901" }, { hike: "0x10" }, { hike: "" }].each do |change|
      get trip_path(valid.merge(change).compact)
      assert_response :bad_request
    end
    assert_empty @requests

    stub_get(TransitousService::PLAN_URL, "{}", status: 503)
    get trip_path(valid)
    assert_response :service_unavailable
  end
end
