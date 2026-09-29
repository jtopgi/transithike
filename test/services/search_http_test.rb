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
    assert_equal 25, SearchHttp.connection(OverpassService::URL, timeout: 25).options.timeout
  end

  test "connections reject oversized streamed responses" do
    on_data = SearchHttp.connection(TransitousService::PLAN_URL).options.on_data
    env = Faraday::Env.new

    on_data.call("{}", 2, env)
    assert_equal "{}", env[:streaming_response_body]
    assert_raises(SearchErrors::UpstreamError) { on_data.call("x", SearchHttp::MAX_RESPONSE_BYTES + 1, env) }
  end

  test "JSON bodies must have the expected shape size and encoding" do
    assert_equal [1], SearchHttp.json(Array) { stub_connection(:get, [1]).get }
    assert_equal({ "a" => 1 }, SearchHttp.json { stub_connection(:get, { "a" => 1 }).get })
    [[1], " " * (SearchHttp::MAX_RESPONSE_BYTES + 1), "{\"a\":\"\xFF\"}".b].each do |body|
      assert_raises(SearchErrors::UpstreamError) { SearchHttp.json { stub_connection(:get, body).get } }
    end
  end
end
