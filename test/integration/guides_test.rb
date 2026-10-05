require "test_helper"
require_relative "../support/guide_fixtures"

class GuidesTest < ActionDispatch::IntegrationTest
  include GuideFixtures

  setup { travel_to Time.utc(2026, 10, 7, 12) }

  teardown do
    GuideService.directory = nil
    travel_back
  end

  # The page's structured data, by type.
  def structured_data
    css_select("script[type='application/ld+json']").to_h { |script| JSON.parse(script.text).then { |data| [data["@type"], data] } }
  end

  test "a city's guide lists its hikes, with what search engines and link previews read" do
    write_guide
    get guide_path("new-york-city")

    assert_response :success
    assert_select "title", "Day hikes by train from New York City · TransitHike"
    assert_select "h1", "Day hikes by train from New York City"
    assert_select "link[rel=canonical][href='http://www.example.com/day-hikes-by-train/new-york-city']"
    assert_select "meta[name=robots]", count: 0
    assert_select "meta[name=description][content^='2 day hikes you can reach by train from Midtown Manhattan, New York City']"
    assert_select "meta[property='og:image'][content='https://upload.wikimedia.org/thumb/Breakneck.jpg/500px-Breakneck.jpg']"
    assert_select ".results-subtitle", text: /Train times are for Saturday, October 10/
    # At a glance: the closest hike, the biggest climb, and the latest trip home.
    facts = css_select(".guide-facts").sole.text.squish
    assert_match(/Closest White Trail \(Tarrytown Lakes\), about 1 h each way/, facts)
    assert_match(/Biggest climb Breakneck Ridge Trail, about 1,250 ft/, facts)
    assert_match(/Sunset 6:24 PM, and every hike is timed to be done by then/, facts)
    cards = css_select("article.trail-card")
    assert_equal ["Breakneck Ridge Trail", "White Trail (Tarrytown Lakes)"], cards.map { |card| card.at_css("h2").text.strip }
    breakneck = cards.first
    assert breakneck.at_css("a[href='/day-hikes-by-train/new-york-city/breakneck-ridge-trail']")
    assert_match(/Each way 1 h 28 min Hudson Line train to Breakneck Ridge/, breakneck.text.squish)
    assert_match(/Hike ≈ 5.0 mi out and back/, breakneck.text.squish)
    # The last trip back leaves before dark, at 6:05 PM, rather than at 8:50 PM.
    assert_match(/↩️ Last trip back 6:05 PM\z/, breakneck.text.squish)
    # Only the hike away from traffic is called quiet, and each says how loud it is along most of it and in places.
    assert_equal [["Quiet"], []], cards.map { |card| card.css(".trail-chip-label").map(&:text).grep(/Quiet/) }
    assert_equal ["🔈 Noise < 45 dB 60–70 dB in places", "🔈 Noise 50–55 dB 70–80 dB in places"],
      cards.map { |card| card.at_css("[data-noise]").ancestors("div").first.text.squish }
    # Without a photo, a card previews its route once it scrolls into view.
    assert cards.last.at_css(".trail-map[data-lazy-map][data-path]")
    list = structured_data.fetch("ItemList")
    assert_equal [2, "http://www.example.com/day-hikes-by-train/new-york-city/breakneck-ridge-trail"],
      [list["numberOfItems"], list["itemListElement"].first["url"]]
    assert_equal ["TransitHike", "Day hikes by train", "New York City"], structured_data.fetch("BreadcrumbList")["itemListElement"].pluck("name")
  end

  test "a guide built from stations says where trips leave from" do
    data = guide_data
    grand_central = { name: "Grand Central", latitude: 40.7527, longitude: -73.9772, id: "us-ny-MetroNorth_1" }
    data[:stations] = [grand_central, { name: "Hoboken", latitude: 40.7347, longitude: -74.0275, id: "hoboken" }]
    data[:hikes].first[:trail][:station] = grand_central
    write_guide(data)

    get guide_path("new-york-city")
    assert_select "meta[name=description][content^='2 day hikes you can reach by train from Grand Central and Hoboken, New York City']"
    assert_select ".results-subtitle", text: /you can reach by train from Grand Central and Hoboken on a Saturday/
    get guide_hike_path("new-york-city", "breakneck-ridge-trail")
    assert_select ".results-subtitle", text: /From Grand Central, it's about 1 h 28 min each way/
    assert_select "caption", text: "Trips there from Grand Central"
    query = URI.decode_www_form(URI(css_select("a[href^='https://www.google.com/maps/dir/']").first["href"]).query).to_h
    assert_equal ["40.7527,-73.9772", "41.443,-73.978"], query.values_at("origin", "destination")
    get llms_path
    assert_includes response.body, "2 hikes from Grand Central and Hoboken, including"
  end

  test "titles show names as they are, with apostrophes and ampersands" do
    data = guide_data
    data[:hikes].first.merge!(title: "Pilgrims' Way & Downs")
    write_guide(data)
    get guide_hike_path("new-york-city", "breakneck-ridge-trail")
    assert_select "title", "Pilgrims' Way & Downs by train from New York City · TransitHike"
    assert_select "meta[property='og:title'][content=?]", "Pilgrims' Way & Downs by train from New York City"
    refute_includes response.body, "&amp;#39;"
  end

  test "a hike's guide page has its trips, timetables, and photos, and links to more hikes" do
    write_guide
    get guide_hike_path("new-york-city", "breakneck-ridge-trail")

    assert_response :success
    assert_select "title", "Breakneck Ridge Trail by train from New York City · TransitHike"
    assert_select "h1", "Breakneck Ridge Trail"
    summary = "Breakneck Ridge Trail is a 5.0-mile hike near Cold Spring, New York (out and back) that climbs about 1,250 ft. " \
      "From Midtown Manhattan, " \
      "it's about 1 h 28 min each way, taking the Hudson Line train to Breakneck Ridge. On Saturdays, the last trip back " \
      "before dark leaves at 6:05 PM."
    assert_select ".results-subtitle", summary
    assert_select "meta[name=description][content=?]", summary
    assert_select ".trail-location", "📍 Cold Spring, New York"
    assert_select "link[rel=canonical][href='http://www.example.com/day-hikes-by-train/new-york-city/breakneck-ridge-trail']"
    assert_select "[data-hike-map][data-path]"
    assert_match(/Sunset 6:23 PM hike done by then ↩️ Last trip back 6:05 PM before dark, from Cold Spring\z/, css_select(".hike-facts").sole.text.squish)
    assert_includes css_select(".hike-facts").sole.text.squish, "🔈 Noise < 45 dB 60–70 dB in places"
    assert_equal "Taking the first trip there, you arrive at 9:40 AM and have up to 8 h 25 min until the last trip back, " \
      "before dark, for a hike of about 2 h 30 min.", css_select(".hike-intro").sole.text.squish
    # Trips back until the last one before dark, at 6:51 PM.
    assert_match(/until the last one before it gets dark, at 6:51 PM\./, css_select("#back-heading + p").sole.text.squish)
    there, back = css_select("table.timetable tbody").map { |table| table.css("tr").map { |row| row.css("td").first.text } }
    assert_equal [["8:12 AM", "9:12 AM", "10:12 AM"], ["3:05 PM", "4:05 PM", "5:05 PM", "6:05 PM"]], [there, back]
    assert_select "tr.timetable-last", text: /6:05 PM.*Last/m
    assert_select "td", text: /Hudson Line from Grand Central to Breakneck Ridge/
    assert_select ".hike-photo img[alt='Breakneck Ridge view']"
    assert_select "a[href='/day-hikes-by-train/new-york-city/white-trail-tarrytown-lakes']", text: "White Trail (Tarrytown Lakes)"
    attraction = structured_data.fetch("TouristAttraction")
    assert_equal ["Breakneck Ridge Trail", 41.443, true], [attraction["name"], attraction.dig("geo", "latitude"), attraction["isAccessibleForFree"]]

    # A hike that's left the guide leads to its city's guide, and unknown cities aren't found.
    get guide_hike_path("new-york-city", "gone-trail")
    assert_redirected_to guide_path("new-york-city")
    get guide_path("atlantis")
    assert_response :not_found
    get guide_path("london")
    assert_response :not_found
  end

  test "the guides, the home page, and what search engines and AI assistants read list each city's guide" do
    write_guide
    get guides_path
    assert_select "h2 a[href='/day-hikes-by-train/new-york-city']", text: "Day hikes by train from New York City"

    get root_path
    assert_select "a.btn[href='/day-hikes-by-train/new-york-city']", text: "New York City"
    assert_select "link[rel=canonical][href='http://www.example.com/']"
    assert_select "meta[property='og:image'][content='http://www.example.com/og-image.png']"
    assert_equal "WebApplication", structured_data.keys.sole

    get sitemap_path
    assert_equal "application/xml", response.media_type
    urls = Nokogiri::XML(response.body).remove_namespaces!.css("url").to_h { |url| [url.at_css("loc").text, url.at_css("lastmod")&.text] }
    assert_equal({ "http://www.example.com/" => nil, "http://www.example.com/day-hikes-by-train" => "2026-10-07T09:00:00Z",
      "http://www.example.com/day-hikes-by-train/new-york-city" => "2026-10-07T09:00:00Z",
      "http://www.example.com/day-hikes-by-train/new-york-city/breakneck-ridge-trail" => "2026-10-07T09:00:00Z",
      "http://www.example.com/day-hikes-by-train/new-york-city/white-trail-tarrytown-lakes" => "2026-10-07T09:00:00Z" }, urls)

    get llms_path
    assert_equal "text/plain", response.media_type
    assert_includes response.body, "- [Day hikes by train from New York City](http://www.example.com/day-hikes-by-train/new-york-city): " \
      "2 hikes from Midtown Manhattan, including Breakneck Ridge Trail and White Trail (Tarrytown Lakes). Updated 2026-10-07."
    # AI assistants are asked to link people to the page they used.
    assert_includes response.body, "Please give people a link to the page you used"
    assert_includes response.body, "http://www.example.com/search?origin=Brooklyn&day=saturday"
  end

  test "crawlers may read every page but not the lookups pages make, which would plan trips for them" do
    get robots_path
    assert_equal "text/plain", response.media_type
    assert_equal "User-agent: *\nAllow: /\nDisallow: /search/stream\nDisallow: /trip\nDisallow: /photos\nDisallow: /places\n" \
      "Disallow: /hike\n\nSitemap: http://www.example.com/sitemap.xml\n", response.body
    refute File.exist?(Rails.root.join("public/robots.txt"))
  end

  test "without published guides, pages still render and the sitemap lists the home page" do
    GuideService.directory = Pathname(Dir.mktmpdir("guides"))
    get root_path
    assert_response :success
    assert_select "#guides-heading", count: 0
    get guides_path
    assert_response :success
    get sitemap_path
    assert_equal ["http://www.example.com/"], Nokogiri::XML(response.body).remove_namespaces!.css("loc").map(&:text)
  end

  test "search engines are asked to verify ownership only when it's set up" do
    get root_path
    assert_select "meta[name=google-site-verification]", count: 0
    ENV["GOOGLE_SITE_VERIFICATION"], ENV["BING_SITE_VERIFICATION"] = "google-token", "bing-token"
    get root_path
    assert_select "meta[name=google-site-verification][content=google-token]"
    assert_select "meta[name='msvalidate.01'][content=bing-token]"
  ensure
    ENV.delete("GOOGLE_SITE_VERIFICATION")
    ENV.delete("BING_SITE_VERIFICATION")
  end
end
