require "application_system_test_case"
require_relative "../services/search_test_support"

class SearchesTest < ApplicationSystemTestCase
  include SearchTestSupport

  # Three routes north of the origin, nearest first, with different lengths and trips.
  ROUTES = [["Short Loop", 47.61, 1, [{ duration: 1800, transfers: 0 }]],
    ["Ridge Trail", 47.63, 5, [{ duration: 1200, transfers: 1 }]],
    ["Long Traverse", 47.66, 8, [{ duration: 2400, transfers: 2 }]]].freeze

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
      stub.post(URI(OverpassService::URL).path) { [200, {}, JSON.generate(elements: ROUTES.each_with_index.map { |route, index| element(*route.first(3), index) })] }
      stub.get(URI(TransitousService::ONE_TO_MANY_URL).path) do
        [200, {}, JSON.generate(transit_durations: ROUTES.map(&:last), street_durations: [])]
      end
      stub.get(URI(WikipediaService::API_URL).path) { [200, {}, "{}"] }
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

  test "results can be sorted and filtered by hike length" do
    visit search_url(origin: "Seattle")

    assert_text "Showing 3 of 3 routes"
    assert_equal ["Ridge Trail", "Short Loop", "Long Traverse"], route_names

    select "Longest hike", from: "Sort by"
    assert_equal ["Long Traverse", "Ridge Trail", "Short Loop"], route_names
    select "Closest", from: "Sort by"
    assert_equal ["Short Loop", "Ridge Trail", "Long Traverse"], route_names

    find("label", text: "Under 3 mi").click
    assert_text "Showing 1 of 3 routes"
    assert_equal ["Short Loop"], route_names
    find("label", text: "Over 6 mi").click
    assert_equal ["Long Traverse"], route_names
  end
end
