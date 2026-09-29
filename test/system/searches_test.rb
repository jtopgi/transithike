require "application_system_test_case"
require_relative "../services/search_test_support"

class SearchesTest < ApplicationSystemTestCase
  include SearchTestSupport

  # Three routes by stations 23 to 29 km north of the origin, nearest first, with different lengths and trips.
  ROUTES = [["Short Loop", 47.81, 1.5, [{ duration: 4800, transfers: 0 }]],
    ["Ridge Trail", 47.83, 5, [{ duration: 4200, transfers: 1 }]],
    ["Long Traverse", 47.86, 8, [{ duration: 6000, transfers: 2 }]]].freeze
  # A waterfall on the Short Loop, a viewpoint on the Long Traverse, and a well-known park around the Ridge Trail.
  HIGHLIGHTS = [["waterfall", 47.815, "Little Falls"], ["viewpoint", 47.95, nil]].freeze
  POPULAR_AREA = "47.9|-122.0"

  setup do
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(URI(PhotonService::URL).path) do |env|
        features = env.params["q"] == "Nowhere" ? [] : [place("Pike Place Market", city: "Seattle"), place("Seattle")]
        [200, {}, JSON.generate(features: features)]
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
      # A station downtown, and trains from there to a station at each route's start, sooner for nearer routes.
      stub.get(URI(TransitousService::ONE_TO_ALL_URL).path) do |env|
        stops = if env.params["transitModes"]
          ROUTES.each_with_index.map { |(_, latitude), index| reached_stop(latitude, -122.0, 10 + index * 5) }
        else
          [reached_stop(47.605, -122.0, 5, id: "downtown")]
        end
        [200, {}, JSON.generate(all: stops)]
      end
      # Trips there; with arriveBy, the last trips back, two hours before the 11 PM deadline; and none by subway.
      stub.get(URI(TransitousService::ONE_TO_MANY_URL).path) do |env|
        durations = if env.params["arriveBy"] == "true"
          ROUTES.map { [{ duration: 7200, transfers: 0 }] }
        else
          env.params["transitModes"] ? ROUTES.map { [] } : ROUTES.map(&:last)
        end
        [200, {}, JSON.generate(transit_durations: durations, street_durations: [])]
      end
      # The trains and buses each card shows once the search is done.
      stub.get(URI(TransitousService::PLAN_URL).path) do |env|
        leave = Time.iso8601(env.params["time"])
        leg = env.params["arriveBy"] == "true" ? { mode: "BUS", routeShortName: "11" } : { mode: "SUBURBAN", routeLongName: "Sounder N Line" }
        start, finish = env.params["arriveBy"] == "true" ? [leave - 3.hours, leave - 2.hours] : [leave + 10.minutes, leave + 1.hour]
        itinerary = { duration: (finish - start).to_i, transfers: 0, startTime: start.utc.iso8601, endTime: finish.utc.iso8601,
          legs: [leg.merge(startTime: start.utc.iso8601, endTime: finish.utc.iso8601, agencyName: "Sound Transit")] }
        [200, {}, JSON.generate(itineraries: [itinerary], direct: [])]
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

  test "suggests starting points as you type and searches the one you choose, for the day you choose" do
    visit root_url
    assert_selector "h1", text: "Weekend hikes you can reach by train"
    assert_button "Use my location"
    assert_equal "rgb(25, 135, 84)", page.evaluate_script(
      "getComputedStyle(document.querySelector('button[type=submit]')).backgroundColor"
    )
    assert_equal page.evaluate_script("Intl.DateTimeFormat().resolvedOptions().timeZone"),
      find("input[name=tz]", visible: false).value

    find("label", text: "Sunday").click
    fill_in "Starting point", with: "Pike"
    find("[role=option]", text: "Pike Place Market, Seattle, Washington, United States").click

    assert_selector "h1", text: "Day hikes by train from Pike Place Market, Seattle, Washington, United States"
    assert_includes current_url, "lat=47.6"
    assert_includes current_url, "day=sunday"
    # On Sunday morning, the trip is that day.
    assert_selector "[data-departure]", text: /\A(Sunday, \w+ \d+|Today), leaving (at 8:00 AM|now)/
    assert_selector "input[name=day][value=sunday]:checked", visible: false
    assert_selector "article.trail-card", count: 3
    assert_no_selector "[data-skeleton]"
    assert_selector ".trail-map.leaflet-container", minimum: 1
    assert_selector "article.trail-card dd", text: "1 transfer"
    assert_selector "article.trail-card .trail-return", text: /Last trip back \d+:\d\d [AP]M/, count: 3
    # Capybara reads non-breaking spaces as spaces.
    assert_selector "[data-departure]", text: /with a way back by 11 PM/
    # Each card shows the trains and other transit there and back once the search is done.
    assert_selector ".trail-trip", text: /There: 🚆 Sounder N Line · leave \d+:\d\d [AP]M, arrive/, minimum: 1
    assert_selector ".trail-trip", text: /Back: 🚌 11 · leave \d+:\d\d [AP]M, home by 9:00 PM/, minimum: 1
    # The planned trips replace the search's estimates: a 50-minute ride, and the last trip back three hours before 11 PM.
    assert_selector "article.trail-card [data-travel-time]", text: "50 min", minimum: 1
    assert_selector "article.trail-card .trail-return", text: /Last trip back 8:00 PM/, minimum: 1
  end

  test "hikes stream in, are ranked once highlights and popularity arrive, and can be sorted and filtered" do
    visit search_url(origin: "Seattle")

    # Popularity arrives with the final ranking.
    assert_selector "article.trail-card", text: /Ridge Trail.*Very popular/m
    assert_selector "article.trail-card", text: /Short Loop.*Little Falls/m
    assert_no_selector "[data-progress]", visible: true
    assert_text "Showing 3 of 3 hikes"
    assert_equal ["Ridge Trail", "Long Traverse", "Short Loop"], route_names

    { "Fastest to reach" => ["Ridge Trail", "Short Loop", "Long Traverse"],
      "Most time there" => ["Ridge Trail", "Short Loop", "Long Traverse"],
      "Most scenic" => ["Short Loop", "Long Traverse", "Ridge Trail"],
      "Most popular" => ["Ridge Trail", "Long Traverse", "Short Loop"],
      "Longest hike" => ["Long Traverse", "Ridge Trail", "Short Loop"],
      "Closest" => ["Short Loop", "Ridge Trail", "Long Traverse"] }.each do |order, names|
      select order, from: "Sort by"
      assert_equal names, route_names, order
    end

    select "Up to 1½ hours", from: "Trip"
    assert_text "Showing 2 of 3 hikes"
    assert_equal ["Short Loop", "Ridge Trail"], route_names
    find("label", text: "Under 3 mi").click
    assert_text "Showing 1 of 3 hikes"
    assert_equal ["Short Loop"], route_names
    find("label", text: "Over 6 mi").click
    assert_text "No hikes match these filters"
    select "Any travel time", from: "Trip"
    assert_equal ["Long Traverse"], route_names
  end

  test "a search that fails says why" do
    visit search_url(origin: "Nowhere")
    assert_selector "[data-failure][role=alert]", text: /could not find that starting point/
    assert_no_selector "[data-progress]", visible: true
    assert_no_selector "[data-skeleton]"
    assert_no_selector "[data-results-toolbar]", visible: true
  end
end
