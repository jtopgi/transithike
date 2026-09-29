require "test_helper"

class WikipediaServiceTest < ActiveSupport::TestCase
  THUMBNAIL = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Park.jpg/500px-Park.jpg"

  def page(title, lat:, image: "Park.jpg", thumbnail: THUMBNAIL, url: "https://en.wikipedia.org/wiki/#{title.tr(' ', '_')}",
    description: nil)
    { "title" => title, "pageimage" => image, "thumbnail" => { "source" => thumbnail }, "fullurl" => url,
      "coordinates" => [{ "lat" => lat, "lon" => -122.4 }], "description" => description }.compact
  end

  def metadata(license: "CC BY-SA 4.0", artist: '<a href="//commons.wikimedia.org/wiki/User:Ann">Ann &amp; Bo</a>')
    { "Artist" => { "value" => artist }, "LicenseShortName" => { "value" => license } }
  end

  def image_info(**credit)
    { "query" => { "pages" => [{ "title" => "File:Park.jpg",
      "imageinfo" => [{ "descriptionurl" => "https://commons.wikimedia.org/wiki/File:Park.jpg", "extmetadata" => metadata(**credit) }] }] } }
  end

  # A photo on Wikimedia Commons, taken lat degrees north of 47.66, -122.4.
  def commons_file(title, lat: 0.001, mime: "image/jpeg", width: 1600, height: 1200, **credit)
    name = title.tr(" ", "_")
    { "title" => "File:#{title}", "coordinates" => [{ "lat" => 47.66 + lat, "lon" => -122.4 }],
      "imageinfo" => [{ "mime" => mime, "width" => width, "height" => height,
        "thumburl" => "https://upload.wikimedia.org/wikipedia/commons/thumb/1/12/#{name}/500px-#{name}",
        "descriptionurl" => "https://commons.wikimedia.org/wiki/File:#{name}", "extmetadata" => metadata(**credit) }] }
  end

  # Answers the nearby-article search and the image details request, or with
  # commons, the search for files taken nearby.
  def connection(pages = [], info = image_info, files: nil, &assert_request)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/") do |request|
        assert_request&.call(request)
        body = if request.params["ggsnamespace"] == "6"
          { "query" => { "pages" => files } }
        elsif request.params["generator"] == "geosearch"
          { "query" => { "pages" => pages } }
        else
          info
        end
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
      end
    end
    Faraday.new { |builder| builder.adapter :test, stubs }
  end

  def photos(pages, info = image_info, files: [], cache: ActiveSupport::Cache::MemoryStore.new, &block)
    WikipediaService.photos_near(47.66, -122.4, connection: connection(pages, info, &block),
      commons: connection(files: files, &block), cache: cache)
  end

  def area(pages, &block)
    WikipediaService.nearby_area(47.6612, -122.4, connection: connection(pages, &block))
  end

  test "the nearest natural area has a title, an article, and a lead image" do
    requests = []
    result = area([page("Magnuson Park", lat: 47.68), page("Discovery Park (Seattle)", lat: 47.661)]) do |request|
      requests << request.params
    end
    assert_equal({ title: "Discovery Park (Seattle)", article_url: "https://en.wikipedia.org/wiki/Discovery_Park_(Seattle)",
      image: "Park.jpg", image_url: THUMBNAIL }, result)
    assert_equal ["47.66|-122.4", "2000", "max", "free"], requests.sole.values_at("ggscoord", "ggsradius", "colimit", "pilicense")
    assert_includes requests.sole["prop"].split("|"), "description"
    refute_includes requests.sole["prop"].split("|"), "pageviews"
  end

  test "descriptions tell natural areas apart, and titles do when there is none" do
    pages = [page("Issaquah Valley Trolley", lat: 47.66, description: "Heritage streetcar in Washington, US"),
      page("Cougar Mountain", lat: 47.661, description: "Neighborhood in Bellevue, Washington"),
      page("Tiger Mountain State Forest", lat: 47.662), page("Twin Peaks", lat: 47.663, description: "Two prominent hills")]
    assert_equal "Tiger Mountain State Forest", area(pages)[:title]
    assert_equal "Twin Peaks", area([pages.first, pages.last])[:title]
    # A description names the kind of thing first, and then where it is, which may be a natural area.
    fort = page("Fort Clinton", lat: 47.66, description: "Fort on the Hudson River during the American Revolutionary War")
    island = page("Iona Island", lat: 47.661, description: "Island of the Hudson River in the town of Stony Point, New York")
    assert_equal "Iona Island", area([fort, island])[:title]
    assert_nil area([fort, page("Doodletown", lat: 47.661, description: "Isolated settlement in the Hudson Highlands")])
    # "Of" is often part of the kind, but places people live aren't natural areas.
    assert_equal "Malvern Hills", area([page("Malvern Hills", lat: 47.66, description: "Range of hills in central England")])[:title]
    assert_equal "Wallkill River", area([page("Wallkill River", lat: 47.66, description: "Tributary of the Hudson River")])[:title]
    assert_nil area([page("Katoomba", lat: 47.66, description: "Suburb of the Blue Mountains, New South Wales, Australia"),
      page("Mürren", lat: 47.661, description: "Mountain village in Switzerland")])
    # Without a description, a title such as this one's is the kind.
    assert_equal "Village Creek State Park", area([page("Village Creek State Park", lat: 47.66)])[:title]
  end

  test "the photos near a route start with the nearest park's lead image, credited to its author and license" do
    requests = []
    result = photos([page("Magnuson Park", lat: 47.68), page("Discovery Park (Seattle)", lat: 47.661)],
      files: [commons_file("Discovery Park bluff view.jpg")]) { |request| requests << request.params }
    assert_equal({ title: "Discovery Park (Seattle)", article_url: "https://en.wikipedia.org/wiki/Discovery_Park_(Seattle)",
      photos: [
        { image_url: THUMBNAIL, caption: "Near Discovery Park (Seattle)", file_url: "https://commons.wikimedia.org/wiki/File:Park.jpg",
          credit: "Ann & Bo · CC BY-SA 4.0" },
        { image_url: "https://upload.wikimedia.org/wikipedia/commons/thumb/1/12/Discovery_Park_bluff_view.jpg/500px-Discovery_Park_bluff_view.jpg",
          file_url: "https://commons.wikimedia.org/wiki/File:Discovery_Park_bluff_view.jpg", credit: "Ann & Bo · CC BY-SA 4.0",
          caption: "Discovery Park bluff view" }
      ] }, result)
    commons = requests.find { |params| params["ggsnamespace"] == "6" }
    assert_equal ["47.66|-122.4", "2000", "500"], commons.values_at("ggscoord", "ggsradius", "iiurlwidth")
    assert_equal "File:Park.jpg", requests.find { |params| params["titles"] }["titles"]
  end

  test "photos taken nearby show the scenery first, then the nearest, and leave out what isn't scenery" do
    files = [
      commons_file("Old barn.jpg", lat: 0.0001), commons_file("Ridge trail in autumn.jpg", lat: 0.01),
      commons_file("Lake at sunset.jpg", lat: 0.005), commons_file("Summit_view_from_the_top.JPEG", lat: 0.002),
      # Maps, signs, buildings, species close-ups, drawings, small or very wide images, and other files.
      commons_file("Park map.jpg"), commons_file("Trailhead signpost.jpg"), commons_file("New office bldg.jpg"),
      commons_file("Clavaria zollingeri 302990109.jpg"), commons_file("Lake painting.jpg"), commons_file("Bear Mountain Inn NY1.jpg"),
      commons_file("Philipstown, NY, town hall.jpg"), commons_file("2015 Ford Explorer XLT 4WD in Oxford White, rear right.jpg"),
      commons_file("Tiny lake.jpg", width: 640), commons_file("Wide lake panorama.jpg", width: 24_000, height: 3_800),
      commons_file("Lake diagram.png", mime: "image/png"), commons_file("Unlicensed lake.jpg", license: nil),
      commons_file("Lake with no place.jpg").except("coordinates")
    ]
    result = photos([], files: files)
    assert_nil result[:title]
    assert_equal ["Summit view from the top", "Lake at sunset", "Ridge trail in autumn", "Old barn"],
      result[:photos].pluck(:caption)
    assert_equal WikipediaService::MAX_PHOTOS,
      photos([], files: (1..12).map { |index| commons_file("Lake #{index}.jpg", lat: index * 0.001) })[:photos].size
  end

  test "without a free lead image or photos taken nearby, there are no photos" do
    assert_nil photos([page("Green Lake Park", lat: 47.66, thumbnail: "https://example.com/park.jpg")])
    assert_nil photos([page("Green Lake Park", lat: 47.66).merge("pageimage" => nil)])
    assert_nil photos([page("Discovery Park", lat: 47.66)], image_info(license: nil))
    assert_nil photos([page("Discovery Park", lat: 47.66)], { "query" => { "pages" => [{ "imageinfo" => "invalid" }] } })
    assert_equal ["Near Discovery Park"], photos([page("Discovery Park", lat: 47.66)])[:photos].pluck(:caption)
  end

  test "skips articles that are not natural areas or are not on Wikipedia" do
    pages = [
      page("Lakeside High School", lat: 47.66), page("Queen Anne", lat: 47.66),
      page("Green Lake Park", lat: 47.66, url: "https://example.com/wiki/Green_Lake_Park"),
      page("Green Lake Park", lat: 47.66).except("coordinates")
    ]
    assert_nil area(pages)
    assert_nil photos(pages)
  end

  test "the river Inn isn't taken for an inn" do
    files = ["Inn in Samedan 2022-09-26 01.jpg", "Inn - Madulain, Switzerland.jpg", "Blick auf den Inn.jpg", "Bear Mountain Inn NY1.jpg",
      "The Holiday Inn Express.jpg"].each_with_index.map { |title, index| commons_file(title, lat: index * 0.001) }
    assert_equal ["Inn in Samedan 2022-09-26 01", "Inn - Madulain, Switzerland", "Blick auf den Inn"],
      photos([], files: files)[:photos].pluck(:caption)
  end

  test "an unknown author still credits the license" do
    lead = photos([page("Discovery Park", lat: 47.66)], image_info(license: "Public domain", artist: nil))[:photos].first
    assert_equal "Public domain", lead[:credit]
  end

  test "names Commons hides for machine readers are credited once" do
    artist = %(<div class="fn value">\nUnknown author<span style="display: none;">Unknown author</span></div>)
    lead = photos([page("Discovery Park", lat: 47.66)], image_info(license: "Public domain", artist: artist))[:photos].first
    assert_equal "Unknown author · Public domain", lead[:credit]
  end

  test "areas and photos taken nearby are shared within about 1 km, credits are cached, and failures surface" do
    cache = ActiveSupport::Cache::MemoryStore.new
    requests = []
    stubbed = connection([page("Discovery Park", lat: 47.66)], files: [commons_file("Lake view.jpg")]) { |request| requests << request.params }
    2.times { WikipediaService.photos_near(47.6601, -122.3951, connection: stubbed, commons: stubbed, cache: cache) }
    WikipediaService.photos_near(47.6649, -122.4011, connection: stubbed, commons: stubbed, cache: cache)
    assert_equal ["47.66|-122.4", "File:Park.jpg", "47.66|-122.4"],
      requests.map { |params| params["ggscoord"] || params["titles"] }

    failing = Faraday.new do |builder|
      builder.adapter :test, Faraday::Adapter::Test::Stubs.new { |stub| stub.get("/") { [503, {}, "{}"] } }
    end
    assert_raises(SearchErrors::UpstreamError) { WikipediaService.photos_near(47.66, -122.4, connection: failing, commons: failing) }
  end
end
