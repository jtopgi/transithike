require "test_helper"
require_relative "search_test_support"

class PhotonServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  def feature(name: "Pike Place Market", lat: 47.6094, lon: -122.3414, **properties)
    { "type" => "Feature", "geometry" => { "type" => "Point", "coordinates" => [lon, lat] },
      "properties" => { "name" => name, "city" => "Seattle", "state" => "Washington", "country" => "United States" }.merge(properties.transform_keys(&:to_s)) }
  end

  def suggest(features, query: "Pike Pl", near: nil, cache: Rails.cache, &block)
    PhotonService.suggest(query, near: near, connection: stub_connection(:get, { "features" => features }, &block), cache: cache)
  end

  test "suggestions have readable labels and skip transit stops" do
    places = suggest([feature, feature(name: "Pike Place", city: nil, state: "California")]) do |request|
      assert_equal "Pike Pl", request.params["q"]
      assert_equal "en", request.params["lang"]
      assert_includes request.params["osm_tag"], "!highway:bus_stop"
      assert_nil request.params["lat"]
    end
    assert_equal ["Pike Place Market, Seattle, Washington, United States", "Pike Place, California, United States"],
      places.map(&:name)
    assert_equal [47.6094, -122.3414], [places.first.latitude, places.first.longitude]
  end

  test "addresses without a name use the street and house number" do
    place = suggest([feature(name: nil, housenumber: "85", street: "Pike Street")]).first
    assert_equal "85 Pike Street, Seattle, Washington, United States", place.name
  end

  test "suggestions near a rough location rank it first" do
    suggest([feature], near: [34.05223, -118.24368]) do |request|
      assert_equal ["34.1", "-118.2", "5", "0.5"], request.params.values_at("lat", "lon", "zoom", "location_bias_scale")
    end
  end

  test "malformed duplicate and excess features are left out" do
    features = [nil, { "properties" => {} }, feature(lat: 91), feature(name: " "), feature, feature] +
      (1..8).map { |index| feature(name: "Place #{index}") }
    places = suggest(features)
    assert_equal PhotonService::MAX_SUGGESTIONS, places.size
    assert_equal 1, places.count { |place| place.name.start_with?("Pike Place Market") }
  end

  test "an unknown place geocodes to nothing, and provider failures surface" do
    assert_nil PhotonService.geocode("nowhere", connection: stub_connection(:get, { "features" => [] }))
    ["invalid", {}, { "features" => nil }].each do |body|
      assert_raises(SearchErrors::UpstreamError) { PhotonService.geocode("origin", connection: stub_connection(:get, body)) }
    end
    assert_raises(SearchErrors::UpstreamError) do
      PhotonService.geocode("origin", connection: stub_connection(:get, {}, status: 429))
    end
  end

  test "suggestions are cached by normalized text and rough location" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    connection = stub_connection(:get, { "features" => [feature] }) { calls += 1 }
    first = PhotonService.suggest("Pike  Pl", connection: connection, cache: cache)
    assert_equal first, PhotonService.suggest(" pike pl ", connection: connection, cache: cache)
    assert_equal 1, calls
    PhotonService.suggest("pike pl", near: [47.6, -122.3], connection: connection, cache: cache)
    assert_equal 2, calls
  end

  test "time zones give a rough location, and unusable ones none" do
    latitude, longitude = PhotonService.zone_center("America/Los_Angeles")
    assert_in_delta 34.05, latitude, 0.1
    assert_in_delta(-118.24, longitude, 0.1)
    [nil, 5, "", "Not/AZone", "../../etc/passwd"].each { |zone| assert_nil PhotonService.zone_center(zone) }
  end

  test "where a point is: its town or city, state or region, and country, from the nearest mapped feature" do
    requests = []
    reverse = lambda do |properties|
      stub_connection(:get, { "features" => [{ "properties" => properties }] }) { |request| requests << request.params }
    end
    cache = ActiveSupport::Cache::MemoryStore.new
    found = PhotonService.locality(41.17003, -74.16001, cache: cache,
      connection: reverse.({ "name" => "Pine Meadow Trail", "city" => "Sloatsburg", "county" => "Rockland", "state" => "New York",
        "country" => "United States" }))
    assert_equal({ locality: "Sloatsburg", region: "New York", country: "United States" }, found)
    assert_equal [{ "lat" => "41.17003", "lon" => "-74.16001", "lang" => "en" }], requests
    # Points about a kilometer apart share the lookup.
    assert_equal found, PhotonService.locality(41.171, -74.161, cache: cache, connection: reverse.({}))
    assert_equal 1, requests.size

    # England is too big to say where a place is, so its county does; towns and villages count when there's no city.
    assert_equal({ locality: "Westhumble", region: "Surrey", country: "United Kingdom" },
      PhotonService.locality(51.25, -0.33, cache: cache, connection: reverse.({ "village" => "Westhumble", "county" => "Surrey",
        "state" => "England", "country" => "United Kingdom" })))
    # Nothing nearby is remembered as nothing.
    nothing = stub_connection(:get, { "features" => [] }) { |request| requests << request.params }
    2.times { assert_nil PhotonService.locality(10.0, 10.0, cache: cache, connection: nothing) }
    assert_equal 3, requests.size
    assert_raises(SearchErrors::UpstreamError) do
      PhotonService.locality(11.0, 11.0, cache: cache, connection: stub_connection(:get, {}, status: 503))
    end
  end
end
