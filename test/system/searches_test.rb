require "application_system_test_case"
require_relative "../services/search_test_support"

class SearchesTest < ApplicationSystemTestCase
  include SearchTestSupport

  # Three routes north of the origin, nearest first, with different lengths and trips.
  ROUTES = [["Short Loop", 47.61, 1, [{ duration: 1800, transfers: 0 }]],
    ["Ridge Trail", 47.63, 5, [{ duration: 1200, transfers: 1 }]],
    ["Long Traverse", 47.66, 8, [{ duration: 4800, transfers: 2 }]]].freeze
  # A waterfall on the Short Loop, a viewpoint on the Long Traverse, and a well-known park around the Ridge Trail.
  HIGHLIGHTS = [["waterfall", 47.615, "Little Falls"], ["viewpoint", 47.75, nil]].freeze
  POPULAR_AREA = "47.7|-122.0"

  setup do
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(URI(PhotonService::URL).path) do
        [200, {}, JSON.generate(features: [place("Pike Place Market", city: "Seattle"), place("Seattle")])]
      end
      stub.get(URI(TransitousService::REVERSE_GEOCODE_URL).path) do
        [200, {}, JSON.generate([{ tz: "America/Los_Angeles", areas: [{ name: "Seattle", default: true }] }])]
      end
      stub.post(URI(OverpassService::URLS.first).path) do |env|
        query = URI.decode_www_form(env.body).to_h.fetch("data")
        routes = ROUTES.each_with_index.map { |route, index| element(*route.first(3), index) }
        highlights = HIGHLIGHTS.map { |kind, latitude, name| highlight_node(kind, latitude, -122.0, name: name) }
        [200, {}, JSON.generate(elements: overpass_elements(query, routes: routes, highlights: highlights))]
      end
      # A stop at each route's start, reached sooner for nearer routes.
      stub.get(URI(TransitousService::ONE_TO_ALL_URL).path) do
        stops = ROUTES.each_with_index.map { |(_, latitude), index| { place: { lat: latitude, lon: -122.0 }, duration: 10 + index * 5, k: 1 } }
        [200, {}, JSON.generate(all: stops)]
      end
      stub.get(URI(TransitousService::ONE_TO_MANY_URL).path) do
        [200, {}, JSON.generate(transit_durations: ROUTES.map(&:last), street_durations: [])]
      end
      stub.get(URI(WikipediaService::API_URL).path) do |env|
        pages = if env.params["ggscoord"] == POPULAR_AREA
          [{ title: "Ridge Park", fullurl: "https://en.wikipedia.org/wiki/Ridge_Park", coordinates: [{ lat: 47.7, lon: -122.0 }],
            pageviews: { "2026-09-01" => 5_000 } }]
        end
        [200, {}, JSON.generate(pages ? { query: { pages: pages } } : {})]
      end
    end
    Faraday.default_adapter = Class.new(Faraday::Adapter::Test) do
      define_method(:initialize) { |app| super(app, stubs) }
    end
    Faraday.default_adapter_options = {}
  end

  teardown do
    Faraday.default_adapter = @old_adapter
    Faraday.default_adapter_options = @old_adapter_options
  end

  def place(name, **properties)
    { geometry: { coordinates: [-122.0, 47.6] },
      properties: { name: name, state: "Washington", country: "United States", **properties } }
  end

  def element(name, latitude, miles, index)
    route = route_element(id: index + 1, latitude: latitude, name: name)
    route["members"].first["geometry"].last["lat"] = latitude + miles * OverpassService::METERS_PER_MILE / 111_195
    route
  end

  def route_names
    all("article.trail-card h2").map(&:text)
  end

  test "suggests starting points as you type and searches the one you choose" do
    visit root_url
    assert_selector "h1", text: "Find hikes you can reach by public transit"
    assert_button "Use my location"
    assert_equal "rgb(25, 135, 84)", page.evaluate_script(
      "getComputedStyle(document.querySelector('button[type=submit]')).backgroundColor"
    )

    fill_in "Starting point", with: "Pike"
    find("[role=option]", text: "Pike Place Market, Seattle, Washington, United States").click

    assert_selector "h1", text: "Hikes near Pike Place Market, Seattle, Washington, United States"
    assert_includes current_url, "lat=47.6"
    assert_selector "article.trail-card", count: 3
    assert_selector ".trail-map.leaflet-container", minimum: 1
    assert_selector "article.trail-card dd", text: "1 transfer"
  end

  test "results are recommended first and can be sorted and filtered by length and trip" do
    visit search_url(origin: "Seattle")

    assert_text "Showing 3 of 3 routes"
    assert_equal ["Ridge Trail", "Short Loop", "Long Traverse"], route_names
    assert_selector "article.trail-card", text: /Ridge Trail.*Very popular/m
    assert_selector "article.trail-card", text: /Short Loop.*Little Falls/m

    { "Fastest to reach" => ["Ridge Trail", "Short Loop", "Long Traverse"],
      "Most scenic" => ["Short Loop", "Long Traverse", "Ridge Trail"],
      "Most popular" => ["Ridge Trail", "Short Loop", "Long Traverse"],
      "Longest hike" => ["Long Traverse", "Ridge Trail", "Short Loop"],
      "Closest" => ["Short Loop", "Ridge Trail", "Long Traverse"] }.each do |order, names|
      select order, from: "Sort by"
      assert_equal names, route_names, order
    end

    select "Up to 1 hour", from: "Trip"
    assert_text "Showing 2 of 3 routes"
    assert_equal ["Short Loop", "Ridge Trail"], route_names
    find("label", text: "Under 3 mi").click
    assert_text "Showing 1 of 3 routes"
    assert_equal ["Short Loop"], route_names
    find("label", text: "Over 6 mi").click
    assert_text "No routes match these filters"
    select "Any travel time", from: "Trip"
    assert_equal ["Long Traverse"], route_names
  end
end
