require "test_helper"
require_relative "search_test_support"

class SearchHttpTest < ActiveSupport::TestCase
  include SearchTestSupport

  test "connections have bounded timeouts and identify the application" do
    connection = SearchHttp.connection(PhotonService::URL)
    assert_equal 5, connection.options.timeout
    assert_equal 3, connection.options.open_timeout
    assert_equal "https", connection.url_prefix.scheme
    assert_match %r{\ATransitHike/\S+ \(\+https://github\.com/\S+\)\z}, connection.headers["User-Agent"]
    assert_equal 25, SearchHttp.connection(OverpassService::URLS.first, timeout: 25).options.timeout
  end

  test "connections reject oversized streamed responses" do
    on_data = SearchHttp.connection(TransitousService::PLAN_URL).options.on_data
    env = Faraday::Env.new

    on_data.call("{}", 2, env)
    assert_equal "{}", env[:streaming_response_body]
    assert_raises(SearchErrors::ResponseTooLarge) { on_data.call("x", SearchHttp::MAX_RESPONSE_BYTES + 1, env) }
  end

  test "connections log which provider failed and how" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/busy") { [429, {}, ""] }
      stub.get("/slow") { raise Faraday::TimeoutError }
      stub.get("/fine") { [200, {}, "{}"] }
    end
    connection = SearchHttp.connection("https://provider.example")
    connection.builder.adapter :test, stubs
    log = StringIO.new
    logger, Rails.logger = Rails.logger, ActiveSupport::Logger.new(log)

    connection.get("/fine")
    connection.get("/busy")
    assert_raises(Faraday::TimeoutError) { connection.get("/slow") }
    assert_equal ["provider.example responded 429", "provider.example failed: TimeoutError"], log.string.lines.map(&:strip)
  ensure
    Rails.logger = logger if logger
  end

  test "requests to a provider that answers only a few at once wait for a slot, and fail when none comes free" do
    stubs = Faraday::Adapter::Test::Stubs.new { |stub| stub.get("/plan") { [200, {}, "{}"] } }
    connection = SearchHttp.connection("https://api.transitous.org")
    connection.builder.adapter :test, stubs
    slots = Rails.configuration.x.provider_slots["api.transitous.org"]
    assert_equal 3, slots.available_permits

    assert_equal "{}", connection.get("/plan").body
    assert_equal 3, slots.available_permits
    # Visitors' requests may take every slot.
    ProviderSlots.with_priority(ProviderSlots::VISITOR) { slots.acquire(3) }
    begin
      error = assert_raises(SearchErrors::ProviderBusy) do
        stub_const(SearchHttp, :SLOT_WAIT_SECONDS, 0.05) { connection.get("/plan") }
      end
    ensure
      slots.release(3)
    end
    assert_equal SearchHttp::BUSY_MESSAGE, error.message
  end

  test "JSON bodies must have the expected shape size and encoding" do
    assert_equal [1], SearchHttp.json(Array) { stub_connection(:get, [1]).get }
    assert_equal({ "a" => 1 }, SearchHttp.json { stub_connection(:get, { "a" => 1 }).get })
    [[1], " " * (SearchHttp::MAX_RESPONSE_BYTES + 1), "{\"a\":\"\xFF\"}".b].each do |body|
      assert_raises(SearchErrors::UpstreamError) { SearchHttp.json { stub_connection(:get, body).get } }
    end
    assert_raises(SearchErrors::ResponseTooLarge) do
      SearchHttp.json { stub_connection(:get, " " * (SearchHttp::MAX_RESPONSE_BYTES + 1)).get }
    end
  end
end
