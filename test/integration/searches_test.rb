require "test_helper"
require_relative "../services/search_test_support"

class SearchesIntegrationTest < ActionDispatch::IntegrationTest
  include SearchTestSupport

  setup do
    travel_to Time.utc(2026, 9, 22, 12)
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
    travel_back
  end

  def valid_params
    {
      origin: "Seattle", maximum_length: "3",
      "arrival_time(1i)" => "2026", "arrival_time(2i)" => "9", "arrival_time(3i)" => "23",
      "arrival_time(4i)" => "12", "arrival_time(5i)" => "30"
    }
  end

  def geocode(matches = [{ type: "PLACE", name: "Seattle", lat: 47, lon: -122, areas: [{ name: "Washington", adminLevel: 4 }] }])
    @stubs.get(URI(TransitousService::GEOCODE_URL).path) do |env|
      assert_equal SearchHttp::USER_AGENT, env.request_headers["User-Agent"]
      [200, {}, JSON.generate(matches)]
    end
  end

  def plan(itineraries: [], direct: [])
    @stubs.get(URI(TransitousService::PLAN_URL).path) do |env|
      assert_equal SearchHttp::USER_AGENT, env.request_headers["User-Agent"]
      [200, {}, JSON.generate(itineraries: itineraries, direct: direct)]
    end
  end

  def hiking(elements)
    @stubs.post(URI(OverpassService::URL).path) { [200, {}, JSON.generate(elements: elements)] }
  end

  test "successful search renders accessible cards with honest geometry source attribution and no photo fallback" do
    geocode
    hiking([route_element(name: "<script>alert(1)</script>")])
    plan(itineraries: [{ duration: 601 }])
    get search_path, params: valid_params.merge(origin: "A & B / 東京")
    assert_response :success
    assert_select "strong", text: "Seattle, Washington"
    assert_select "article.card", count: 1
    assert_select "th[scope=row]", count: 2
    assert_select "td", text: "11 minutes"
    assert_select "a[href='https://www.openstreetmap.org/relation/123']", count: 1
    assert_select "a[href='https://transitous.org/sources/']", text: "data sources"
    assert_select "a[href='https://www.openstreetmap.org/copyright']", count: 1
    assert_select "a[href^='https://www.google.com/maps/dir/?']" do |links|
      query = URI.decode_www_form(URI(links.first["href"]).query).to_h
      assert_equal "A & B / 東京", query["origin"]
      assert_equal "47.0,-122.0", query["destination"]
      assert_equal "transit", query["travelmode"]
    end
    assert_select "img", count: 0
    assert_select "script", text: "alert(1)", count: 0
    assert_includes response.body, "&lt;script&gt;"
    assert_includes response.body, "not a verified trailhead"
    @stubs.verify_stubbed_calls
  end

  test "no mapped routes render empty state" do
    geocode
    hiking([])
    get search_path, params: valid_params
    assert_response :success
    assert_select "[role=status]", text: /No hiking routes/
    @stubs.verify_stubbed_calls
  end

  test "unreachable transit route renders empty state" do
    geocode
    hiking([route_element])
    plan
    get search_path, params: valid_params
    assert_response :success
    assert_select "[role=status]", text: /No hiking routes/
    @stubs.verify_stubbed_calls
  end

  test "invalid scalar origins and length are rejected before external requests" do
    [nil, "", "   ", "a" * 201, ["Seattle"], { city: "Seattle" }].each do |origin|
      get search_path, params: valid_params.merge(origin: origin)
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /Enter an origin/
    end
    [nil, "0", "31", "-1", "1.5", "3x", ["3"], { value: "3" }].each do |length|
      get search_path, params: valid_params.merge(maximum_length: length)
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /maximum length/
    end
  end

  test "missing impossible malformed past and too distant arrival dates are rejected" do
    [
      { "arrival_time(1i)" => nil }, { "arrival_time(1i)" => ["2026"] },
      { "arrival_time(2i)" => "2", "arrival_time(3i)" => "30" },
      { "arrival_time(2i)" => "13" }, { "arrival_time(4i)" => "24" },
      { "arrival_time(5i)" => "60" }, { "arrival_time(3i)" => "21" },
      { "arrival_time(3i)" => "30" }, { "arrival_time(1i)" => "202x" }
    ].each do |invalid|
      get search_path, params: valid_params.merge(invalid)
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /arrival/
    end
    get search_path
    assert_response :unprocessable_content
  end

  test "unknown origin renders actionable 422" do
    geocode([])
    get search_path, params: valid_params
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /could not find that origin/
  end

  test "upstream errors are safe service unavailable responses" do
    @stubs.get(URI(TransitousService::GEOCODE_URL).path) { [503, {}, '{"error":"private provider details"}'] }
    get search_path, params: valid_params
    assert_response :service_unavailable
    assert_select "[role=alert]", text: /unavailable/
    refute_includes response.body, "private provider details"
  end

  test "Overpass malformed response is not an empty success" do
    geocode
    @stubs.post(URI(OverpassService::URL).path) { [200, {}, "not json"] }
    get search_path, params: valid_params
    assert_response :service_unavailable
  end

  test "transit timeout is a service failure" do
    geocode
    hiking([route_element])
    @stubs.get(URI(TransitousService::PLAN_URL).path) { raise Faraday::TimeoutError, "sensitive details" }
    get search_path, params: valid_params
    assert_response :service_unavailable
    refute_includes response.body, "sensitive details"
  end
end
