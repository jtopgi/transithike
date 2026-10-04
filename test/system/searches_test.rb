require "application_system_test_case"
require_relative "../services/search_test_support"

class SearchesTest < ApplicationSystemTestCase
  include SearchTestSupport

  # Three routes by stations 23 to 29 km north of the origin, nearest first, with different lengths and trips.
  ROUTES = [["Short Loop", 47.81, 1.5, [{ duration: 4800, transfers: 0 }]],
    ["Ridge Trail", 47.83, 5, [{ duration: 4200, transfers: 1 }]],
    ["Long Traverse", 47.86, 8, [{ duration: 6000, transfers: 2 }]]].freeze
  # A waterfall on the Short Loop and a viewpoint on the Long Traverse; the Ridge Trail climbs to a summit.
  HIGHLIGHTS = [["waterfall", 47.815, "Little Falls"], ["viewpoint", 47.95, nil]].freeze
  SUMMIT = 47.9024
  # Photos taken near every route.
  PHOTOS = ["Ridge view.jpg", "Lake at dawn.jpg", "Autumn woods.jpg"].freeze

  setup do
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(URI(PhotonService::URL).path) do |env|
        features = env.params["q"] == "Nowhere" ? [] : [place("Pike Place Market", city: "Seattle"), place("Seattle")]
        [200, {}, JSON.generate(features: features)]
      end
      # Every route is in Snohomish.
      stub.get(URI(PhotonService::REVERSE_URL).path) do
        [200, {}, JSON.generate(features: [{ properties: { city: "Snohomish", state: "Washington", country: "United States" } }])]
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
      # Trips there; with arriveBy, the last trips back from each route and its far end, two hours before the 11 PM
      # deadline; and none by subway.
      stub.get(URI(TransitousService::ONE_TO_MANY_URL).path) do |env|
        durations = if env.params["arriveBy"] == "true"
          env.params["many"].split(",").map { [{ duration: 7200, transfers: 0 }] }
        else
          env.params["transitModes"] ? ROUTES.map { [] } : ROUTES.map(&:last)
        end
        [200, {}, JSON.generate(transit_durations: durations, street_durations: [])]
      end
      # The train there and the buses back that each card shows once the search is done, riding five minutes
      # less each way than the search's estimate for the route. Buses back leave six and three hours before 11 PM.
      stub.get(URI(TransitousService::PLAN_URL).path) do |env|
        back = env.params["arriveBy"] == "true"
        latitude = Float(env.params[back ? "fromPlace" : "toPlace"].split(",").first)
        ride = ROUTES.min_by { |_, route_latitude| (route_latitude - latitude).abs }.last.sole[:duration] - 300
        time = Time.iso8601(env.params["time"])
        starts = back ? [time - 6.hours, time - 3.hours] : [time + 10.minutes]
        leg = back ? { mode: "BUS", routeShortName: "11" } : { mode: "SUBURBAN", routeLongName: "Sounder N Line" }
        itineraries = starts.map do |start|
          times = { startTime: start.utc.iso8601, endTime: (start + ride).utc.iso8601 }
          { duration: ride, transfers: 0, **times, legs: [leg.merge(times, agencyName: "Sound Transit")] }
        end
        [200, {}, JSON.generate(itineraries: itineraries, direct: [])]
      end
      # The land rises 480 m to a summit at the end of the Ridge Trail, and is flat elsewhere.
      stub.get(/\A#{Regexp.escape(URI(ElevationService::TILE_URL).path)}/) do |env|
        [200, {}, terrain_tile(env.url.path) { |latitude| 480 - (latitude - SUMMIT).abs * 40_000 }]
      end
      # No park nearby on Wikipedia, and photos on Wikimedia Commons, which answers at the same path.
      stub.get(URI(WikipediaService::API_URL).path) do |env|
        files = PHOTOS.each_with_index.map do |title, index|
          name = title.tr(" ", "_")
          { pageid: index + 1, title: "File:#{title}", coordinates: [{ lat: Float((env.params["ggscoord"] || "47.83").split("|").first), lon: -122.0 }],
            imageinfo: [{ mime: "image/jpeg", width: 1600, height: 1200, thumburl: "https://upload.wikimedia.org/thumb/#{name}/500px-#{name}",
              descriptionurl: "https://commons.wikimedia.org/wiki/File:#{name}",
              extmetadata: { Artist: { value: "Ann" }, LicenseShortName: { value: "CC BY 4.0" } } }] }
        end
        # Files nearby, and then their details.
        [200, {}, JSON.generate(env.params["ggsnamespace"] == "6" || env.params["pageids"] ? { query: { pages: files } } : {})]
      end
    end
    Faraday.default_adapter = Class.new(Faraday::Adapter::Test) do
      define_method(:initialize) { |app| super(app, stubs) }
    end
    Faraday.default_adapter_options = {}
    ElevationService::TILES.clear
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
    assert_selector "article.trail-card .trail-return", text: /Last trip back( from the far end)? \d+:\d\d [AP]M/, count: 3
    # Capybara reads non-breaking spaces as spaces.
    assert_selector "[data-departure]", text: /with a way back by 11 PM/
    # Each card shows the trains and other transit there and back once the search is done, and the planned
    # trips replace the search's estimates: the rides there and back, and the last trip back and time there.
    assert_selector ".trail-trip", text: /There: 🚆 Sounder N Line · leave \d+:\d\d [AP]M, arrive/, minimum: 1
    within find("article.trail-card", text: "Short Loop") do
      # The first bus back after the hike, and the last one, which leaves time to stay longer.
      assert_selector ".trail-trip", text: "First back: 🚌 11 · leave 5:00 PM, home 6:15 PM"
      assert_selector ".trail-trip", text: "Last back: 🚌 11 · leave 8:00 PM, home 9:15 PM"
      assert_selector "[data-travel-time]", text: "2 h 30 min"
      assert_selector "[data-travel-detail]", text: "1 h 15 min there · 1 h 15 min back"
      assert_selector ".trail-return", text: "Last trip back 8:00 PM · up to 10 h there"
    end
  end

  # Moves a slider to a value, as dragging it does.
  def slide(selector, value)
    page.execute_script(<<~JS, selector, value.to_s)
      const input = document.querySelector(arguments[0])
      input.value = arguments[1]
      input.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  test "hikes stream in, are ranked most scenic first once highlights and terrain arrive, and can be filtered" do
    visit search_url(origin: "Seattle")

    # Views and highlights arrive with the final ranking.
    assert_selector "article.trail-card", text: /Ridge Trail.*Big views/m
    assert_selector "article.trail-card", text: /Short Loop.*Little Falls/m
    assert_no_selector "[data-progress]", visible: true
    assert_text "Showing 3 of 3 hikes"
    # The Ridge Trail's grand view beats the Short Loop's waterfall, and both beat one small viewpoint.
    assert_equal ["Ridge Trail", "Short Loop", "Long Traverse"], route_names
    assert_selector "article.trail-card", text: /Ridge Trail.*Climb\s+≈ 1,550 ft/m
    assert_no_text "Distance"

    # The routes are hiked out and back, 3 and 10 miles, except the Long Traverse, 16 miles out and back, which is
    # hiked 8 miles to its far end. Planned trips there and back keep these orders.
    within(find("article.trail-card", text: "Long Traverse")) do
      assert_text(/Hike\s+≈ 8.0 mi\s+one way, back from the far end/)
      assert_text "Last trip back from the far end 8:00 PM"
      assert_selector ".trail-trip", text: "First back from the end: 🚌 11 · leave 5:00 PM, home 6:35 PM"
      assert_selector ".trail-trip", text: "Last back from the end: 🚌 11 · leave 8:00 PM, home 9:35 PM"
      assert_link "🧭 Directions back"
    end
    # The sliders narrow hikes down, so there's no other order to choose.
    assert_no_selector "select"
    # Where each route is shows with its trips.
    assert_selector "article.trail-card [data-location]:not(.invisible)", text: "📍 Snohomish, Washington", count: 3

    # Planned trips count from the next change, which fits the round-trip slider to them: the hikes' round trips
    # are 2 h 10 min to 3 h 10 min as planned, so even its quickest end shows the quickest hike.
    { "Ridge Trail" => "1 h 5 min there", "Short Loop" => "1 h 15 min there", "Long Traverse" => "1 h 35 min there" }.each do |name, there|
      assert_selector "article.trail-card", text: /#{name}.*#{there}/m
    end
    slide "[data-max-trip]", 480
    trip = find("[data-max-trip]")
    assert_equal [135, 195], [trip["min"].to_i, trip["max"].to_i]
    slide "[data-max-trip]", 0
    assert_text "Showing 1 of 3 hikes"
    assert_equal ["Ridge Trail"], route_names
    slide "[data-max-trip]", 180
    assert_text "Round trip: up to 3 h"
    assert_text "Showing 2 of 3 hikes"
    assert_equal ["Ridge Trail", "Short Loop"], route_names
    slide "[data-length-min]", 3
    assert_text "Length: 3 mi or more"
    assert_equal ["Ridge Trail", "Short Loop"], route_names
    slide "[data-length-max]", 6
    assert_text "Length: 3–6 mi"
    assert_text "Showing 1 of 3 hikes"
    assert_equal ["Short Loop"], route_names
    # The handles can't pass each other.
    slide "[data-length-min]", 7
    assert_text "Length: 7–7 mi"
    assert_text "No hikes match these filters"
    slide "[data-length-max]", 20
    slide "[data-max-trip]", 480
    assert_text "Round trip: any"
    assert_equal ["Ridge Trail", "Long Traverse"], route_names
    slide "[data-length-min]", 1
    assert_text "Length: any"
    assert_text "Showing 3 of 3 hikes"
  end

  test "each card shows photos taken nearby, and its thumbnails switch between them" do
    # Photos load from Wikimedia, which the test browser isn't allowed to reach.
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: ["*wikimedia.org*"])
    visit search_url(origin: "Seattle")

    within find("article.trail-card", text: "Short Loop") do
      assert_selector ".trail-thumb", count: 3
      thumbs = all(".trail-thumb")
      assert_equal ["Photo 1 of 3: Ridge view", "true"], [thumbs.first["aria-label"], thumbs.first["aria-pressed"]]
      thumbs.last.click
      assert_selector ".trail-thumb[aria-pressed='true']", count: 1
      assert_equal "true", thumbs.last["aria-pressed"]
      assert_match %r{/120px-Autumn_woods\.jpg\z}, thumbs.last.find("img", visible: :all)["src"]
    end
  end

  test "a search that fails says why" do
    visit search_url(origin: "Nowhere")
    assert_selector "[data-failure][role=alert]", text: /could not find that starting point/
    assert_no_selector "[data-progress]", visible: true
    assert_no_selector "[data-skeleton]"
    assert_no_selector "[data-results-toolbar]", visible: true
  end
end
