require "test_helper"
require_relative "search_test_support"

class GoogleMapsServiceTest < ActiveSupport::TestCase
  include SearchTestSupport

  def origin
    GoogleMapsService::Location.new(latitude: 47.0, longitude: -122.0)
  end

  def transit(connection)
    GoogleMapsService.transit_duration(
      origin: origin, destination: origin, arrival_time: Time.iso8601("2026-09-23T12:30:00-07:00"),
      connection: connection, key: "test-only-key"
    )
  end

  test "geocoding REST maps coordinates and encodes origin" do
    connection = stub_connection(:get, { "status" => "OK", "results" => [{ "geometry" => { "location" => { "lat" => 47, "lng" => -122 } } }] }) do |request|
      assert_equal "A & B", request.params["address"]
      assert_equal "test-only-key", request.params["key"]
    end
    result = GoogleMapsService.geocode("A & B", connection: connection, key: "test-only-key")
    assert_equal 47, result.latitude
    assert_equal(-122, result.longitude)
  end

  test "missing geocode is distinct from provider failure" do
    assert_nil GoogleMapsService.geocode("unknown", connection: stub_connection(:get, { "status" => "ZERO_RESULTS", "results" => [] }), key: "test-only-key")
    [
      { "status" => "REQUEST_DENIED", "results" => [] },
      { "status" => "OK", "results" => [] },
      { "status" => "OK", "results" => [nil] },
      { "status" => "OK", "results" => [{ "geometry" => [] }] },
      { "status" => "OK", "results" => [{ "geometry" => { "location" => { "lat" => 91, "lng" => 0 } } }] }
    ].each do |body|
      assert_raises(SearchErrors::UpstreamError) { GoogleMapsService.geocode("origin", connection: stub_connection(:get, body), key: "test-only-key") }
    end
  end

  test "Routes REST uses transit RFC3339 arrival time server header and duration mask" do
    connection = stub_connection(:post, { "routes" => [{ "duration" => "123.5s" }, { "duration" => "200s" }] }) do |request|
      body = JSON.parse(request.body)
      assert_equal "TRANSIT", body.fetch("travelMode")
      assert_equal "2026-09-23T19:30:00Z", body.fetch("arrivalTime")
      assert_equal({ "latitude" => 47.0, "longitude" => -122.0 }, body.dig("origin", "location", "latLng"))
      assert_equal "routes.duration", request.request_headers["X-Goog-FieldMask"]
      assert_equal "test-only-key", request.request_headers["X-Goog-Api-Key"]
      refute_includes request.body, "test-only-key"
    end
    assert_equal 123.5, transit(connection)
  end

  test "no transit route supports omitted protobuf array and empty array" do
    assert_nil transit(stub_connection(:post, {}))
    assert_nil transit(stub_connection(:post, { "routes" => [] }))
  end

  test "invalid durations malformed JSON and API errors surface" do
    [
      "invalid", [], { "error" => { "message" => "test-only-key" } },
      { "routes" => nil }, { "routes" => [nil] }, { "routes" => [{}] },
      { "routes" => [{ "duration" => "-1s" }] }, { "routes" => [{ "duration" => 30 }] }
    ].each do |body|
      error = assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:post, body)) }
      refute_includes error.message, "test-only-key"
    end
    assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:post, {}, status: 503)) }
  end

  test "network failures and timeouts surface safely" do
    [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |error_type|
      connection = stub_connection(:post, {}) { raise error_type, "secret provider details" }
      error = assert_raises(SearchErrors::UpstreamError) { transit(connection) }
      refute_includes error.message, "secret provider details"
    end
  end

  test "connections have bounded timeouts" do
    connection = SearchHttp.connection(GoogleMapsService::ROUTES_URL)
    assert_equal 5, connection.options.timeout
    assert_equal 3, connection.options.open_timeout
    assert_equal "https", connection.url_prefix.scheme
    assert_equal 25, SearchHttp.connection(OverpassService::URL, timeout: 25).options.timeout
  end

  test "connections reject oversized streamed responses" do
    on_data = SearchHttp.connection(GoogleMapsService::ROUTES_URL).options.on_data
    env = Faraday::Env.new

    on_data.call("{}", 2, env)
    assert_equal "{}", env[:streaming_response_body]
    assert_raises(SearchErrors::UpstreamError) { on_data.call("x", SearchHttp::MAX_RESPONSE_BYTES + 1, env) }
  end

  test "server environment key takes precedence with credentials fallback and missing key error" do
    credentials = Struct.new(:google_maps_key).new("credential-test-key")
    assert_equal "environment-test-key", GoogleMapsService.api_key(environment: { "GOOGLE_MAPS_API_KEY" => "environment-test-key" }, credentials: credentials)
    assert_equal "credential-test-key", GoogleMapsService.api_key(environment: {}, credentials: credentials)
    assert_equal "credential-test-key", GoogleMapsService.api_key(environment: { "GOOGLE_MAPS_API_KEY" => "" }, credentials: credentials)
    credentials.google_maps_key = nil
    error = assert_raises(SearchErrors::UpstreamError) { GoogleMapsService.api_key(environment: {}, credentials: credentials) }
    assert_includes error.message, "not configured"
  end

  test "oversized JSON responses and nonfinite durations are rejected" do
    assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:post, " " * (SearchHttp::MAX_RESPONSE_BYTES + 1))) }
    assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:post, { "routes" => [{ "duration" => "#{'9' * 400}s" }] })) }
    assert_raises(SearchErrors::UpstreamError) { transit(stub_connection(:post, { "routes" => [], "error" => {} })) }
  end

  test "environment key never decrypts credentials" do
    credentials = Object.new
    credentials.define_singleton_method(:google_maps_key) { raise "Credentials must not be decrypted" }
    assert_equal "environment-test-key", GoogleMapsService.api_key(
      environment: { "GOOGLE_MAPS_API_KEY" => "environment-test-key" }, credentials: credentials
    )
  end

  test "missing master key is an actionable provider configuration error" do
    [false, true].each do |require_key|
      credentials = ActiveSupport::EncryptedConfiguration.new(
        config_path: Rails.root.join("config/credentials.yml.enc"),
        key_path: Rails.root.join("test/fixtures/files/nonexistent-master.key"),
        env_key: "TRANSITHIKE_TEST_MISSING_MASTER_KEY", raise_if_missing_key: require_key
      )
      error = assert_raises(SearchErrors::UpstreamError) do
        GoogleMapsService.api_key(environment: {}, credentials: credentials)
      end
      assert_includes error.message, "not configured"
    end
  end

  test "unreadable encrypted credentials fail gracefully without exposing details" do
    credentials = Object.new
    credentials.define_singleton_method(:google_maps_key) do
      raise ActiveSupport::MessageEncryptor::InvalidMessage, "private credential details"
    end
    error = assert_raises(SearchErrors::UpstreamError) do
      GoogleMapsService.api_key(environment: {}, credentials: credentials)
    end
    assert_includes error.message, "not configured"
    refute_includes error.message, "private credential details"
  end
end
