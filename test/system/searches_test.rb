require "application_system_test_case"
require_relative "../services/search_test_support"

class SearchesTest < ApplicationSystemTestCase
  include SearchTestSupport

  setup do
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(URI(TransitousService::GEOCODE_URL).path) do
        [200, {}, JSON.generate([{ type: "PLACE", name: "Seattle", lat: 47.6, lon: -122.3, tz: "America/Los_Angeles",
          areas: [{ name: "Washington", adminLevel: 4 }] }])]
      end
      stub.post(URI(OverpassService::URL).path) do
        [200, {}, JSON.generate(elements: [route_element(name: "Forest Loop")])]
      end
      stub.get(URI(TransitousService::PLAN_URL).path) do
        [200, {}, JSON.generate(itineraries: [{ duration: 2400 }], direct: [])]
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

  test "search form is styled and suggests an arrival time" do
    visit root_url

    assert_selector "h1", text: "Find hikes you can reach by public transit"
    assert_field "Starting point"
    assert_select "Longest hike", options: (1..30).map { |miles| "#{miles} mi" }, selected: "5 mi"
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/, find_field("Arrive by").value)
    assert_equal "rgb(25, 135, 84)", page.evaluate_script(
      "getComputedStyle(document.querySelector('button[type=submit]')).backgroundColor"
    )
  end

  test "searching from the form lists routes by travel time" do
    visit root_url
    fill_in "Starting point", with: "Seattle"
    select "8 mi", from: "Longest hike"
    click_on "Find hikes"

    assert_selector "h1", text: "Hiking routes"
    assert_text "Showing routes near Seattle, Washington"
    assert_selector "article.trail-card h2", text: "Forest Loop"
    assert_selector "article.trail-card dd", text: "40 min"

    click_on "Change search"
    assert_field "Starting point", with: "Seattle"
    assert_select "Longest hike", selected: "8 mi"
  end
end
