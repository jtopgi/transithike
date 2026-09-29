require "test_helper"

class WikipediaServiceTest < ActiveSupport::TestCase
  THUMBNAIL = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Park.jpg/500px-Park.jpg"
  VIEWS = { "2026-09-01" => 400, "2026-09-02" => nil, "2026-09-03" => 373 }.freeze

  def page(title, lat:, image: "Park.jpg", thumbnail: THUMBNAIL, url: "https://en.wikipedia.org/wiki/#{title.tr(' ', '_')}",
    views: VIEWS, description: nil)
    { "title" => title, "pageimage" => image, "thumbnail" => { "source" => thumbnail }, "fullurl" => url,
      "coordinates" => [{ "lat" => lat, "lon" => -122.4 }], "pageviews" => views, "description" => description }.compact
  end

  def image_info(license: "CC BY-SA 4.0", artist: '<a href="//commons.wikimedia.org/wiki/User:Ann">Ann &amp; Bo</a>')
    metadata = { "Artist" => { "value" => artist }, "LicenseShortName" => { "value" => license } }
    { "query" => { "pages" => [{ "title" => "File:Park.jpg",
      "imageinfo" => [{ "descriptionurl" => "https://commons.wikimedia.org/wiki/File:Park.jpg", "extmetadata" => metadata }] }] } }
  end

  # Answers the nearby-article search, a page views request, and the image details request.
  def connection(pages, info = image_info, views: {}, &assert_request)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/") do |request|
        assert_request&.call(request)
        body = if request.params["generator"] == "geosearch"
          { "query" => { "pages" => pages } }
        elsif request.params["prop"] == "pageviews"
          { "query" => { "pages" => [{ "title" => request.params["titles"], "pageviews" => views }] } }
        else
          info
        end
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
      end
    end
    Faraday.new { |builder| builder.adapter :test, stubs }
  end

  def photo(pages, info = image_info, &block)
    WikipediaService.photo_near(47.66, -122.4, connection: connection(pages, info, &block))
  end

  def area(pages, **options, &block)
    WikipediaService.nearby_area(47.6612, -122.4, connection: connection(pages, **options, &block))
  end

  test "the nearest natural area's page views show how well known it is" do
    requests = []
    result = area([page("Magnuson Park", lat: 47.68), page("Discovery Park (Seattle)", lat: 47.661)]) do |request|
      requests << request.params
    end
    assert_equal({ title: "Discovery Park (Seattle)", article_url: "https://en.wikipedia.org/wiki/Discovery_Park_(Seattle)",
      monthly_views: 773, image: "Park.jpg", image_url: THUMBNAIL }, result)
    assert_equal ["47.66|-122.4", "2000", "max", "30"], requests.sole.values_at("ggscoord", "ggsradius", "colimit", "pvipdays")
    assert_includes requests.sole["prop"].split("|"), "description"
  end

  test "page views left for a later batch are requested for the chosen area" do
    requests = []
    result = area([page("Discovery Park", lat: 47.66, views: nil)], views: { "2026-09-01" => 12, "2026-09-02" => 30 }) do |request|
      requests << request.params
    end
    assert_equal 42, result[:monthly_views]
    assert_equal ["Discovery Park", "pageviews"], requests.last.values_at("titles", "prop")
    assert_equal 0, area([page("Discovery Park", lat: 47.66, views: nil)], views: nil)[:monthly_views]
  end

  test "descriptions tell natural areas apart, and titles do when there is none" do
    pages = [page("Issaquah Valley Trolley", lat: 47.66, description: "Heritage streetcar in Washington, US"),
      page("Cougar Mountain", lat: 47.661, description: "Neighborhood in Bellevue, Washington"),
      page("Tiger Mountain State Forest", lat: 47.662), page("Twin Peaks", lat: 47.663, description: "Two prominent hills")]
    assert_equal "Tiger Mountain State Forest", area(pages)[:title]
    assert_equal "Twin Peaks", area([pages.first, pages.last])[:title]
  end

  test "areas without a free image still count toward popularity but have no photo" do
    pages = [page("Green Lake Park", lat: 47.66, thumbnail: "https://example.com/park.jpg")]
    assert_equal({ title: "Green Lake Park", article_url: "https://en.wikipedia.org/wiki/Green_Lake_Park",
      monthly_views: 773, image: nil, image_url: nil }, area(pages))
    assert_nil photo(pages)
    assert_nil photo([page("Green Lake Park", lat: 47.66).merge("pageimage" => nil)])
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

  test "skips articles that are not natural areas or are not on Wikipedia" do
    pages = [
      page("Lakeside High School", lat: 47.66), page("Queen Anne", lat: 47.66),
      page("Green Lake Park", lat: 47.66, url: "https://example.com/wiki/Green_Lake_Park"),
      page("Green Lake Park", lat: 47.66).except("coordinates")
    ]
    assert_nil area(pages)
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

  test "areas are shared within about 1 km, photo credits are cached, and failures surface" do
    cache = ActiveSupport::Cache::MemoryStore.new
    requests = []
    stubbed = connection([page("Discovery Park", lat: 47.66)]) { |request| requests << request.params }
    WikipediaService.nearby_area(47.6649, -122.4011, connection: stubbed, cache: cache)
    2.times { WikipediaService.photo_near(47.6601, -122.3951, connection: stubbed, cache: cache) }
    assert_equal ["47.66|-122.4", "File:Park.jpg"], requests.map { |params| params["ggscoord"] || params["titles"] }

    failing = Faraday.new do |builder|
      builder.adapter :test, Faraday::Adapter::Test::Stubs.new { |stub| stub.get("/") { [503, {}, "{}"] } }
    end
    assert_raises(SearchErrors::UpstreamError) { WikipediaService.photo_near(47.66, -122.4, connection: failing) }
  end
end
