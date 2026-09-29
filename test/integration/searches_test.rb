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
  # back, which by default leave two hours before the 11 PM deadline; and with
  # transitModes, trips by city transit, which by default reach nothing.
  def transit(trips, returns: nil, city: nil, walks: [])
    stub_get(TransitousService::ONE_TO_MANY_URL) do |env|
      back = env.params["arriveBy"] == "true"
      durations = if back
        returns || trips.map { [{ duration: 7200, transfers: 0 }] }
      elsif env.params["transitModes"]
        city || trips.map { [] }
      else
        trips
      end
      [200, {}, JSON.generate(transit_durations: durations, street_durations: back || env.params["transitModes"] ? [] : walks)]
    end
  end

  def wikipedia(pages = [])
    stub_get(WikipediaService::API_URL, { query: { pages: pages } })
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
    assert_select "[data-results-toolbar][hidden] select[data-sort] option", count: 8
    assert_select "select[data-sort] option:first-child[value=recommended]"
    assert_select "select[data-sort] option[value=stay]", text: "Most time there"
    assert_select "[data-results-toolbar] select[data-max-trip] option", count: 5
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
    wikipedia
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
    assert_equal ["2026-09-27T06:00:00Z", "true"], returns.values_at("time", "arriveBy")
    # The station is on the line between two tiles, so routes within a walk of it are in either.
    assert_includes @requests["overpass"].first, 'relation["type"="route"]["route"="hiking"](47.0,-122.5,47.5,-121.5)->.region;'

    place = data_for("place").sole
    assert_equal "Day hikes by train from Seattle, Washington, United States", place["heading"]
    assert_equal "Saturday, September 26, leaving at 8:00\u00a0AM\u00a0PDT, with a way back by 11\u00a0PM.", place["departure"]
    assert_equal "America/Los_Angeles", place["time_zone"]
    assert_equal [{ "count" => 1 }], data_for("checking")

    card = cards.at_css("[data-trail][data-osm-id='123'][data-duration='5400'][data-length='1.38'][data-distance='20.73']" \
      "[data-popularity='0'][data-scenic='0']")
    assert card
    # Arriving at 9:30 AM with the last trip back at 9 PM leaves 11 hours 30 minutes.
    assert_equal "41400", card["data-stay"]
    assert card.at_css(".trail-map[data-path='[[[47.3,-122.0],[47.32,-122.0]]]'][data-start='[47.3,-122.0]']")
    assert card.at_css("a[data-photo-url='#{photo_path(lat: 47.32, lon: -122.0)}'][hidden]")
    assert_match(/90 min\s+1 transfer/, card.at_css(".trail-stats").text)
    assert_match(/Last trip back 9:00 PM\s+· up to 11 h there/, card.at_css(".trail-return").text.squish)
    trip_url = card.at_css("[data-trip-url]")["data-trip-url"]
    assert_equal trip_path(from: "47.0,-122.0", to: "47.3,-122.0", leave: "2026-09-26T15:00:00Z", back_by: "2026-09-27T06:00:00Z"), trip_url
    assert card.at_css("a[href='https://www.openstreetmap.org/relation/123'][target=_blank]")
    query = URI.decode_www_form(URI(card.at_css("a[href^='https://www.google.com/maps/dir/?']")["href"]).query).to_h
    assert_equal ["Seattle, Washington, United States", "47.3,-122.0", "transit"], query.values_at("origin", "destination", "travelmode")
    assert_nil card.at_css("script")
    assert_includes card.to_html, "&lt;script&gt;"

    update = data_for("update").sole["trails"].sole
    assert_equal [123, 0, 0], update.values_at("id", "popularity", "scenic")
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

  test "hikes are joined where the train reaches them soonest, then ranked with highlights and popularity" do
    area
    rail([[47.32, -122.001, 50]])
    route = route_element(latitude: 47.3, name: "Falls Loop")
    hiking([route], highlights: [highlight_node("waterfall", 47.305, -122.0005, name: "Twin Falls")])
    transit([[{ duration: 2400, transfers: 1 }]])
    wikipedia([{ title: "Twin Falls State Park", fullurl: "https://en.wikipedia.org/wiki/Twin_Falls_State_Park",
      coordinates: [{ lat: 47.31, lon: -122.0 }], pageviews: { "2026-09-01" => 2_500 } }])
    search_all(origin: "Pike Place Market", lat: "47.0", lon: "-122.0")

    assert_empty @requests["/api/"]
    assert_equal "Day hikes by train from Pike Place Market", data_for("place").sole["heading"]
    assert_equal "47.3200000;-122.0000000", @requests[URI(TransitousService::ONE_TO_MANY_URL).path].first.params["many"]
    card = cards.at_css("[data-trail]")
    assert card.at_css(".trail-map[data-start='[47.32,-122.0]']")
    query = URI.decode_www_form(URI(card.at_css("a[href^='https://www.google.com/maps/dir/?']")["href"]).query).to_h
    assert_equal "47.32,-122.0", query["destination"]

    update = data_for("update").sole["trails"].sole
    assert_equal [2_500, 2], update.values_at("popularity", "scenic")
    chips = Nokogiri::HTML5.fragment(update["chips"])
    assert chips.at_css(".trail-chip[title='2,500 Wikipedia page views of Twin Falls State Park in the last 30 days']")
    assert chips.at_css(".trail-chip[title='Waterfall: Twin Falls']")
    assert_equal ["Very popular", "Twin Falls"], chips.css(".trail-chip-label").map(&:text)
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
    wikipedia
    search_all(origin: SearchesController::CURRENT_LOCATION, lat: "47.0", lon: "-122.0")

    assert_equal "Day hikes by train from your location in Seattle", data_for("place").sole["heading"]
    assert_match(/67 min\s+direct/, cards.at_css(".trail-stats").text)
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
    wikipedia
    search_all(origin: "Seattle")

    assert_match(/80 min\s+2 transfers/, cards.at_css(".trail-stats").text)
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

  def leg(mode, name, start, finish)
    { mode: mode, routeShortName: name, agencyName: "Metro", headsign: "Downtown", startTime: start, endTime: finish }
  end

  def journey(start, finish, legs)
    { duration: (Time.iso8601(finish) - Time.iso8601(start)).to_i, transfers: 0, startTime: start, endTime: finish, legs: legs }
  end

  test "a trip lists the trains, buses, and ferries there and the last ones back" do
    stub_get(TransitousService::PLAN_URL) do |env|
      body = if env.params["arriveBy"] == "true"
        { itineraries: [journey("2026-09-24T01:23:00Z", "2026-09-24T04:21:00Z", [leg("BUS", "206", "2026-09-24T01:23:00Z", "2026-09-24T01:40:00Z")])], direct: [] }
      else
        { itineraries: [journey("2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z", [leg("REGIONAL_RAIL", "Cascades", "2026-09-23T15:30:00Z", "2026-09-23T17:02:00Z")])], direct: [] }
      end
      [200, {}, JSON.generate(body)]
    end
    get trip_path(from: "47.6,-122.3", to: "48.4,-122.3", leave: "2026-09-23T15:00:00Z", back_by: "2026-09-24T06:00:00Z")

    assert_response :success
    there, back = response.parsed_body.values_at("there", "back")
    assert_equal ["2026-09-23T15:19:00Z", "2026-09-23T17:31:00Z"], there.values_at("departure", "arrival")
    assert_equal [{ "mode" => "REGIONAL_RAIL", "name" => "Cascades", "agency" => "Metro", "headsign" => "Downtown" }], there["legs"]
    assert_equal ["2026-09-24T01:23:00Z", "206"], [back["departure"], back["legs"].sole["name"]]
    there_request, back_request = @requests[URI(TransitousService::PLAN_URL).path].map(&:params)
    assert_equal ["47.6000000,-122.3000000", "48.4000000,-122.3000000", "false"], there_request.values_at("fromPlace", "toPlace", "arriveBy")
    assert_equal ["48.4000000,-122.3000000", "47.6000000,-122.3000000", "true"], back_request.values_at("fromPlace", "toPlace", "arriveBy")
    assert_equal "private", response.headers["Cache-Control"].split(", ").find { |part| part.start_with?("private") }
  end

  test "trips need two points and times on one day, and provider failures say so" do
    valid = { from: "47.6,-122.3", to: "48.4,-122.3", leave: "2026-09-23T15:00:00Z", back_by: "2026-09-24T06:00:00Z" }
    [{ from: "91,0" }, { to: "north" }, { from: nil }, { leave: "tomorrow" }, { back_by: "2026-09-23T14:00:00Z" },
      { back_by: "2026-09-26T06:00:00Z" }, { leave: "2026-10-30T15:00:00Z", back_by: "2026-10-31T06:00:00Z" }].each do |change|
      get trip_path(valid.merge(change).compact)
      assert_response :bad_request
    end
    assert_empty @requests

    stub_get(TransitousService::PLAN_URL, "{}", status: 503)
    get trip_path(valid)
    assert_response :service_unavailable
  end
end
