require "test_helper"

class PlacesAndPhotosTest < ActionDispatch::IntegrationTest
  setup do
    @old_adapter = Faraday.default_adapter
    @old_adapter_options = Faraday.default_adapter_options
    @stubs = Faraday::Adapter::Test::Stubs.new
    stubs = @stubs
    Faraday.default_adapter = Class.new(Faraday::Adapter::Test) do
      define_method(:initialize) { |app| super(app, stubs) }
    end
    Faraday.default_adapter_options = {}
  end

  teardown do
    Faraday.default_adapter = @old_adapter
    Faraday.default_adapter_options = @old_adapter_options
  end

  test "suggests places for typed text, ranked near the visitor's time zone" do
    requests = []
    @stubs.get(URI(PhotonService::URL).path) do |env|
      requests << env.params
      [200, {}, JSON.generate(features: [{ geometry: { coordinates: [-122.34, 47.61] },
        properties: { name: "Pike Place Market", city: "Seattle", state: "Washington", country: "United States" } }])]
    end
    get places_path, params: { q: "  Pike   Pl ", tz: "America/Los_Angeles" }

    assert_response :success
    assert_equal [{ "name" => "Pike Place Market, Seattle, Washington, United States", "lat" => 47.61, "lon" => -122.34 }],
      response.parsed_body
    assert_equal ["Pike Pl", "34.1", "-118.2"], requests.first.values_at("q", "lat", "lon")
    assert_match(/max-age=3600/, response.headers["Cache-Control"])
  end

  test "short or malformed queries get no suggestions without a request" do
    [nil, "Se", ["Seattle"], "a" * 101].each do |query|
      get places_path, params: { q: query }
      assert_response :success
      assert_equal [], response.parsed_body
    end
  end

  test "suggestion failures return an empty list" do
    @stubs.get(URI(PhotonService::URL).path) { [429, {}, "{}"] }
    get places_path, params: { q: "Seattle" }
    assert_response :service_unavailable
    assert_equal [], response.parsed_body
  end

  test "returns credited photos of the scenery near a route" do
    # Wikipedia and Wikimedia Commons answer at the same path, and Commons is asked for files.
    @stubs.get(URI(WikipediaService::API_URL).path) do |env|
      body = if env.params["ggsnamespace"] == "6"
        { query: { pages: [{ title: "File:Discovery Park view.jpg", coordinates: [{ lat: 47.661, lon: -122.41 }],
          imageinfo: [{ mime: "image/jpeg", width: 1600, height: 1200, thumburl: "https://upload.wikimedia.org/view.jpg",
            descriptionurl: "https://commons.wikimedia.org/wiki/File:Discovery_Park_view.jpg",
            extmetadata: { Artist: { value: "Bo" }, LicenseShortName: { value: "CC0" } } }] }] } }
      elsif env.params["generator"] == "geosearch"
        { query: { pages: [{ title: "Discovery Park (Seattle)", pageimage: "Park.jpg", fullurl: "https://en.wikipedia.org/wiki/Discovery_Park",
          thumbnail: { source: "https://upload.wikimedia.org/park.jpg" }, coordinates: [{ lat: 47.66, lon: -122.41 }] }] } }
      else
        { query: { pages: [{ imageinfo: [{ descriptionurl: "https://commons.wikimedia.org/wiki/File:Park.jpg",
          extmetadata: { Artist: { value: "Ann" }, LicenseShortName: { value: "CC BY 4.0" } } }] }] } }
      end
      [200, {}, JSON.generate(body)]
    end
    get photos_path, params: { lat: "47.66", lon: "-122.41" }

    assert_response :success
    assert_equal ["Discovery Park (Seattle)", "https://en.wikipedia.org/wiki/Discovery_Park"],
      response.parsed_body.values_at("title", "article_url")
    assert_equal [["Near Discovery Park (Seattle)", "https://upload.wikimedia.org/park.jpg", "Ann · CC BY 4.0"],
      ["Discovery Park view", "https://upload.wikimedia.org/view.jpg", "Bo · CC0"]],
      response.parsed_body["photos"].map { |photo| photo.values_at("caption", "image_url", "credit") }
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  test "photos are empty when none is nearby, and invalid or failed requests say so" do
    @stubs.get(URI(WikipediaService::API_URL).path) { [200, {}, "{}"] }
    get photos_path, params: { lat: "47.66", lon: "-122.41" }
    assert_response :no_content

    [{}, { lat: "91", lon: "0" }, { lat: ["1"], lon: "0" }, { lat: "north", lon: "0" }].each do |params|
      get photos_path, params: params
      assert_response :bad_request
    end
  end

  test "photo provider failures are service unavailable" do
    @stubs.get(URI(WikipediaService::API_URL).path) { [503, {}, "{}"] }
    get photos_path, params: { lat: "47.66", lon: "-122.41" }
    assert_response :service_unavailable
  end
end
