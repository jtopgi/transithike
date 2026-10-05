require "test_helper"

class StopListTest < ActiveSupport::TestCase
  # The stops read from the body, given to the list in pieces of size bytes.
  def read(body, size)
    stops = []
    list = StopList.new { |stop| stops << stop }
    body.b.scan(/.{1,#{size}}/m) { |piece| list << piece }
    list.finish
    stops
  end

  def stop(name, rides: 1)
    { "place" => { "name" => name, "lat" => 47.5, "lon" => -122.0, "modes" => ["BUS"] }, "duration" => 30, "k" => rides }
  end

  test "stops are read one at a time however the response arrives, whatever their names hold" do
    # Names can hold the text between two stops, or after the last, as long as its quotes are escaped.
    all = [stop(%(Odd },{"place": name)), stop("Zürich HB", rides: 0), stop(%(Last }] stop))]
    [JSON.generate("one" => { "lat" => 47.6 }, "all" => all), JSON.generate("all" => all, "one" => { "lat" => 47.6 })].each do |body|
      [1, 2, 7, 64, body.bytesize].each { |size| assert_equal all, read(body, size), "in pieces of #{size} bytes" }
    end
    assert_empty read(JSON.generate("one" => {}, "all" => []), 3)
  end

  test "a response that isn't a list of stops fails" do
    ['{"error":"Not found"}', '{"all":[1,2]}', '{"all":[{"place":{"lat":1}}', ""].each do |body|
      assert_raises(SearchErrors::UpstreamError, body) { read(body, 5) }
    end
    # Without the list, or with stops that never end, it fails before reading much.
    stub_const(StopList, :MAX_UNREAD_BYTES, 100) do
      assert_raises(SearchErrors::UpstreamError) { read(%({"one":{"name":"#{'x' * 200}"}}), 50) }
      assert_raises(SearchErrors::UpstreamError) do
        read(JSON.generate("all" => [{ "duration" => 1, "k" => 1, "place" => { "name" => "x" * 200 } }] * 2), 50)
      end
    end
  end
end
