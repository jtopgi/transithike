require "test_helper"

class WikipediaServiceTest < ActiveSupport::TestCase
  THUMBNAIL = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Park.jpg/500px-Park.jpg"

  def page(title, lat:, image: "Park.jpg", thumbnail: THUMBNAIL, url: "https://en.wikipedia.org/wiki/#{title.tr(' ', '_')}")
    { "title" => title, "pageimage" => image, "thumbnail" => { "source" => thumbnail }, "fullurl" => url,
      "coordinates" => [{ "lat" => lat, "lon" => -122.4 }] }
  end

  def image_info(license: "CC BY-SA 4.0", artist: '<a href="//commons.wikimedia.org/wiki/User:Ann">Ann &amp; Bo</a>')
    metadata = { "Artist" => { "value" => artist }, "LicenseShortName" => { "value" => license } }
    { "query" => { "pages" => [{ "title" => "File:Park.jpg",
      "imageinfo" => [{ "descriptionurl" => "https://commons.wikimedia.org/wiki/File:Park.jpg", "extmetadata" => metadata }] }] } }
  end

  # Answers the nearby-article search and then the image details request.
  def connection(pages, info = image_info, &assert_request)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/") do |request|
        assert_request&.call(request)
        body = request.params["generator"] == "geosearch" ? { "query" => { "pages" => pages } } : info
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
      end
    end
    Faraday.new { |builder| builder.adapter :test, stubs }
  end

  def photo(pages, info = image_info, &block)
    WikipediaService.photo_near(47.66, -122.4, connection: connection(pages, info, &block))
  end

  test "uses the nearest park's lead image with its author and license" do
    requests = []
    result = photo([page("Magnuson Park", lat: 47.68), page("Discovery Park (Seattle)", lat: 47.661)]) { |request| requests << request.params }
    assert_equal({
      title: "Discovery Park (Seattle)", article_url: "https://en.wikipedia.org/wiki/Discovery_Park_(Seattle)",
      image_url: THUMBNAIL, file_url: "https://commons.wikimedia.org/wiki/File:Park.jpg", credit: "Ann & Bo · CC BY-SA 4.0"
    }, result)
    assert_equal ["47.66|-122.4", "2000", "free"], requests.first.values_at("ggscoord", "ggsradius", "pilicense")
    assert_equal "File:Park.jpg", requests.last["titles"]
  end

  test "skips articles that are not natural areas or lack usable images" do
    pages = [
      page("Lakeside High School", lat: 47.66), page("Queen Anne", lat: 47.66),
      page("Green Lake Park", lat: 47.66, thumbnail: "https://example.com/park.jpg"),
      page("Green Lake Park", lat: 47.66, url: "https://example.com/wiki/Green_Lake_Park"),
      page("Green Lake Park", lat: 47.66).merge("pageimage" => nil)
    ]
    assert_nil photo(pages)
    assert_nil photo([])
  end

  test "photos without a license are left out" do
    assert_nil photo([page("Discovery Park", lat: 47.66)], image_info(license: nil))
    assert_nil photo([page("Discovery Park", lat: 47.66)], { "query" => { "pages" => [{ "imageinfo" => "invalid" }] } })
  end

  test "an unknown author still credits the license" do
    assert_equal "Public domain", photo([page("Discovery Park", lat: 47.66)], image_info(license: "Public domain", artist: nil))[:credit]
  end

  test "results are cached by rough location and failures surface" do
    cache = ActiveSupport::Cache::MemoryStore.new
    calls = 0
    stubbed = connection([page("Discovery Park", lat: 47.66)]) { calls += 1 }
    2.times { WikipediaService.photo_near(47.6601, -122.4, connection: stubbed, cache: cache) }
    assert_equal 2, calls

    failing = Faraday.new do |builder|
      builder.adapter :test, Faraday::Adapter::Test::Stubs.new { |stub| stub.get("/") { [503, {}, "{}"] } }
    end
    assert_raises(SearchErrors::UpstreamError) { WikipediaService.photo_near(47.66, -122.4, connection: failing) }
  end
end
