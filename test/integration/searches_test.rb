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

  # Arrival is wall-clock time at the origin: 12:30 PDT is 19:30 UTC.
  def valid_params
    { origin: "Seattle", arrival_time: "2026-09-23T12:30", maximum_length: "3" }
  end

  def geocode(matches = [{ type: "PLACE", name: "Seattle", lat: 47, lon: -122, tz: "America/Los_Angeles",
    areas: [{ name: "Washington", adminLevel: 4 }] }])
    @stubs.get(URI(TransitousService::GEOCODE_URL).path) do |env|
      assert_equal SearchHttp::USER_AGENT, env.request_headers["User-Agent"]
      [200, {}, JSON.generate(matches)]
    end
  end

  def plan(itineraries: [], direct: [])
    @stubs.get(URI(TransitousService::PLAN_URL).path) do |env|
      assert_equal SearchHttp::USER_AGENT, env.request_headers["User-Agent"]
      assert_equal "2026-09-23T19:30:00Z", env.params["time"]
      [200, {}, JSON.generate(itineraries: itineraries, direct: direct)]
    end
  end

  def hiking(elements)
    @stubs.post(URI(OverpassService::URL).path) { [200, {}, JSON.generate(elements: elements)] }
  end

  test "the search form sends exactly the parameters the search reads" do
    get root_path
    assert_response :success
    assert_equal %w[origin arrival_time maximum_length],
      css_select("form[action='#{search_path}'] [name]").map { |field| field["name"] }
    assert_select "input[type=datetime-local][name=arrival_time][required]"
    assert_select "select[name=maximum_length] option[selected]", text: "5 mi"
  end

  test "the search form is refilled from a previous search" do
    get root_path, params: valid_params.merge(maximum_length: "8", origin: ["ignored"])
    assert_select "input[name=origin]:not([value])"
    assert_select "input[name=arrival_time][value='2026-09-23T12:30']"
    assert_select "select[name=maximum_length] option[selected]", text: "8 mi"
  end

  test "successful search renders accessible cards with honest geometry source attribution and no photo fallback" do
    geocode
    hiking([route_element(name: "<script>alert(1)</script>")])
    plan(itineraries: [{ duration: 601 }])
    get search_path, params: valid_params.merge(origin: "A & B / 東京")
    assert_response :success
    assert_select "strong", text: "Seattle, Washington"
    assert_select "strong", text: "Wed, Sep 23 at 12:30 PM PDT"
    assert_select "a[href=?]", root_path(valid_params.merge(origin: "A & B / 東京")), text: /Change search/
    assert_select "article.trail-card", count: 1
    assert_select "article.trail-card dt", count: 2
    assert_select "article.trail-card dd", text: "11 min"
    assert_select "a[href='https://www.openstreetmap.org/relation/123'][target=_blank]", count: 1
    assert_select "footer a[href='https://transitous.org/sources/']", text: "data sources"
    assert_select "footer a[href='https://www.openstreetmap.org/copyright']", count: 1
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

  test "missing and malformed arrival times are rejected before external requests" do
    [
      nil, "", ["2026-09-23T12:30"], { date: "2026-09-23" }, "2026-02-30T10:00", "2026-13-01T10:00",
      "2026-09-23T24:00", "2026-09-23T12:60", "202x-09-23T12:30", "2026-09-23 12:30", "2026-09-23"
    ].each do |arrival_time|
      get search_path, params: valid_params.merge(arrival_time: arrival_time)
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: "Choose a valid arrival date and time."
    end
    get search_path
    assert_response :unprocessable_content
  end

  test "arrival times with seconds are accepted" do
    geocode
    hiking([])
    get search_path, params: valid_params.merge(arrival_time: "2026-09-23T12:30:00.000")
    assert_response :success
  end

  test "past and too distant arrival times are rejected in the origin's time zone" do
    geocode
    # It is 05:00 PDT on September 22.
    %w[2026-09-22T04:59 2026-09-29T05:01].each do |arrival_time|
      get search_path, params: valid_params.merge(arrival_time: arrival_time)
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /in the future, within the next 7 days.*\(PDT\)/
    end
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
