require "test_helper"
require_relative "../services/search_test_support"

class SearchesIntegrationTest < ActionDispatch::IntegrationTest
  include SearchTestSupport

  setup do
    travel_to Time.utc(2026, 9, 22, 22) # 3 PM in Seattle, so trips plan for 8 AM tomorrow.
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

  # Both Overpass instances answer the area, route details and highlights queries.
  def hiking(routes, highlights: [], paved: [])
    OverpassService::URLS.each do |url|
      @stubs.post(URI(url).path) do |env|
        query = URI.decode_www_form(env.body).to_h.fetch("data")
        [200, {}, JSON.generate(elements: overpass_elements(query, routes: routes, highlights: highlights, paved: paved))]
      end
    end
  end

  def stops(*stops)
    stub_get(TransitousService::ONE_TO_ALL_URL, { all: stops.map { |lat, lon, minutes, rides| { place: { lat: lat, lon: lon }, duration: minutes, k: rides } } })
  end

  def trips(*durations)
    stub_get(TransitousService::ONE_TO_MANY_URL, { transit_durations: durations, street_durations: [] })
  end

  test "the home page asks only for a starting point" do
    get root_path
    assert_response :success
    assert_equal %w[origin lat lon], css_select("form[action='#{search_path}'] [name]").map { |field| field["name"] }
    assert_select "input[name=origin][role=combobox][aria-controls=origin-suggestions][required]"
    assert_select "input[name=lat][disabled]"
    assert_select "button[data-use-location][hidden]"
  end

  test "a typed place lists routes with previews, trip details, and attribution" do
    geocode
    area
    hiking([route_element(name: "<script>alert(1)</script>")])
    trips([{ duration: 2400, transfers: 1 }])
    get search_path, params: { origin: "A & B / 東京" }

    assert_response :success
    assert_equal "A & B / 東京", @requests["/api/"].first.params["q"]
    assert_equal "47.0000000;-122.0000000", @requests[URI(TransitousService::ONE_TO_MANY_URL).path].first.params["one"]
    assert_equal "2026-09-23T15:00:00Z", @requests[URI(TransitousService::ONE_TO_MANY_URL).path].first.params["time"]
    assert_select "h1", text: "Hikes near Seattle, Washington, United States"
    assert_includes response.body, "Travel times for leaving tomorrow at 8:00 AM PDT."
    assert_select "[data-trail][data-rank='0'][data-duration='2400'][data-length='0.69'][data-distance='0.0']" \
      "[data-popularity='0'][data-scenic='0']", count: 1
    assert_select ".trail-map[data-path='[[[47.0,-122.0],[47.01,-122.0]]]'][data-start='[47.0,-122.0]']"
    assert_select "a[data-photo-url='#{photo_path(lat: 47.01, lon: -122.0)}'][hidden]"
    assert_select ".trail-chips", count: 0
    assert_select ".trail-card dd", text: /40 min\s+1 transfer/
    assert_select "a[href='https://www.openstreetmap.org/relation/123'][target=_blank]", count: 1
    assert_select "a[href^='https://www.google.com/maps/dir/?']" do |links|
      query = URI.decode_www_form(URI(links.first["href"]).query).to_h
      assert_equal ["Seattle, Washington, United States", "47.0,-122.0", "transit"], query.values_at("origin", "destination", "travelmode")
    end
    assert_select "[data-results-toolbar][hidden] select[data-sort] option", count: 7
    assert_select "[data-results-toolbar] select[data-sort] option:first-child[value=recommended]"
    assert_select "[data-results-toolbar] select[data-max-trip] option", count: 4
    assert_select "footer a[href='https://transitous.org/sources/']", text: "data sources"
    assert_select "footer a[href='https://photon.komoot.io']", text: "Photon"
    assert_select "script", text: "alert(1)", count: 0
    assert_includes response.body, "&lt;script&gt;"
    assert_includes response.body, "not to a verified trailhead"
  end

  test "routes show popularity, highlights and paving, and are joined where transit reaches them soonest" do
    area
    stops([47.11, -122.001, 30, 1])
    route = route_element(latitude: 47.1, name: "Falls Loop")
    hiking([route], highlights: [highlight_node("waterfall", 47.105, -122.0005, name: "Twin Falls")], paved: [123])
    trips([{ duration: 2400, transfers: 1 }])
    stub_get(WikipediaService::API_URL, { query: { pages: [{ title: "Twin Falls State Park", fullurl: "https://en.wikipedia.org/wiki/Twin_Falls_State_Park",
      coordinates: [{ lat: 47.105, lon: -122.0 }], pageviews: { "2026-09-01" => 2_500 } }] } })
    get search_path, params: { origin: "Pike Place Market", lat: "47.0", lon: "-122.0" }

    assert_response :success
    assert_equal "47.1100000;-122.0000000", @requests[URI(TransitousService::ONE_TO_MANY_URL).path].first.params["many"]
    assert_select "[data-trail][data-popularity='2500'][data-scenic='2']", count: 1
    assert_select ".trail-map[data-start='[47.11,-122.0]']"
    assert_select ".trail-chip", count: 3
    assert_select ".trail-chip[title='2,500 Wikipedia page views of Twin Falls State Park in the last 30 days']", text: /Very popular/
    assert_select ".trail-chip[title='Waterfall: Twin Falls']", text: /Twin Falls/
    assert_select ".trail-chip", text: /Mostly paved/
    assert_select "a[href^='https://www.google.com/maps/dir/?']" do |links|
      assert_equal "47.11,-122.0", URI.decode_www_form(URI(links.first["href"]).query).to_h["destination"]
    end
  end

  test "a chosen suggestion searches its coordinates without a lookup" do
    area
    hiking([route_element])
    trips([{ duration: 600, transfers: 0 }])
    get search_path, params: { origin: "Pike Place Market", lat: "47.0", lon: "-122.0" }

    assert_response :success
    assert_empty @requests["/api/"]
    assert_select "h1", text: "Hikes near Pike Place Market"
    assert_select ".trail-card dd", text: /10 min\s+direct/
    assert_select "input[name=lat][value='47.0']:not([disabled])"
  end

  test "the device's location is named after its area and starts directions from it" do
    area
    hiking([route_element])
    stub_get(TransitousService::ONE_TO_MANY_URL, { transit_durations: [[]], street_durations: [{ duration: 900 }] })
    get search_path, params: { origin: SearchesController::CURRENT_LOCATION, lat: "47.0", lon: "-122.0" }

    assert_response :success
    assert_select "h1", text: "Hikes near your location in Seattle"
    assert_select ".trail-card dd", text: /15 min\s+on foot/
    assert_select "a[href^='https://www.google.com/maps/dir/?']" do |links|
      refute_includes URI.decode_www_form(URI(links.first["href"]).query).to_h, "origin"
    end
  end

  test "invalid coordinates fall back to looking up the typed place" do
    geocode
    area
    hiking([])
    get search_path, params: { origin: "Seattle", lat: "91", lon: "-122.0" }
    assert_response :success
    assert_equal 1, @requests["/api/"].size
  end

  test "trips fall back to planning each route when the one-request API fails" do
    geocode
    area
    hiking([route_element])
    stub_get(TransitousService::ONE_TO_MANY_URL, "not json")
    stub_get(TransitousService::PLAN_URL, { itineraries: [{ duration: 1800, transfers: 2 }], direct: [] })
    get search_path, params: { origin: "Seattle" }
    assert_response :success
    assert_select ".trail-card dd", text: /30 min\s+2 transfers/
  end

  test "a failed area lookup still searches, in UTC" do
    geocode
    stub_get(TransitousService::REVERSE_GEOCODE_URL, "{}", status: 503)
    hiking([])
    get search_path, params: { origin: "Seattle" }
    assert_response :success
    assert_includes response.body, "Travel times for leaving tomorrow at 8:00 AM UTC."
  end

  test "no reachable routes render an empty state, and old search parameters are ignored" do
    geocode
    area
    hiking([route_element])
    trips([])
    get search_path, params: { origin: "Seattle", arrival_time: "2026-09-23T12:30", maximum_length: "3" }
    assert_response :success
    assert_select "[role=status]", text: /No hiking routes/
    assert_select "[data-trail]", count: 0
  end

  test "invalid origins are rejected before external requests" do
    [nil, "", "   ", "a" * 201, ["Seattle"], { city: "Seattle" }].each do |origin|
      get search_path, params: { origin: origin }
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /Enter a starting point/
    end
    assert_empty @requests
  end

  test "an unknown place renders an actionable 422" do
    geocode([])
    get search_path, params: { origin: "Nowhere" }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /could not find that starting point/
  end

  test "place search failures are safe service unavailable responses" do
    stub_get(PhotonService::URL, '{"error":"private provider details"}', status: 503)
    get search_path, params: { origin: "Seattle" }
    assert_response :service_unavailable
    assert_select "[role=alert]", text: /unavailable/
    refute_includes response.body, "private provider details"
  end

  test "a malformed route response is not an empty success" do
    geocode
    area
    OverpassService::URLS.each { |url| @stubs.post(URI(url).path) { [200, {}, "not json"] } }
    get search_path, params: { origin: "Seattle" }
    assert_response :service_unavailable
  end
end
