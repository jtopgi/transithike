# The nearest Wikipedia article about a park or natural area near a route: its
# page views show how well known the place is, and its lead image, served from
# Wikimedia Commons under a free license that requires crediting the author,
# illustrates the route card.
module WikipediaService
  API_URL = "https://en.wikipedia.org/w/api.php"
  RADIUS_METERS = 2_000
  THUMBNAIL_WIDTH = 500
  CACHE_TTL = 7.days
  CREDIT_CACHE_TTL = 30.days
  VIEW_DAYS = 30
  NATURAL = /\b(?:parks?|trails?|lakes?|mount(?:ain)?s?|forests?|creeks?|falls|waterfalls?|preserve|reserve|natural area|wilderness|peaks?|summits?|rivers?|beach(?:es)?|woods|gardens?|arboretum|canyons?|gorge|ridges?|hills?|bay|ponds?|marsh|wetlands?|greenway|valley|islands?|glacier|nature|headland|cape|bluffs?|cliffs?|dunes?|meadows?|prairie)\b/i
  BUILT = /\b(?:schools?|station|university|college|church|hospital|airport|mall|stadium|library|museum|company|corporation|district|building|tower|bridge|hotel|apartments?|condominiums?|highway|interchange|railway|railroad|zoo|cemetery|memorial|monument)\b/i

  # { title:, article_url:, monthly_views:, image:, image_url: }, or nil when no
  # park or natural area is nearby. monthly_views covers the last 30 days.
  def self.nearby_area(latitude, longitude, connection: nil, cache: Rails.cache)
    # Routes joined within about 1 km of each other share one lookup.
    latitude, longitude = latitude.round(2), longitude.round(2)
    cache.fetch("wikipedia:area:v1:#{latitude}:#{longitude}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(API_URL)
      page = nearest_natural_page(latitude, longitude, connection)
      next unless page

      image = page["pageimage"].is_a?(String) && wikimedia_url?(value_at(page, "thumbnail", "source"))
      # Views for many pages arrive in batches, so the chosen page's may need a request of their own.
      views = page["pageviews"]
      views = query(connection, titles: page["title"], prop: "pageviews", pvipdays: VIEW_DAYS).first&.dig("pageviews") unless views.is_a?(Hash)
      views = views.is_a?(Hash) ? views.values.grep(Integer).sum : 0
      { title: page["title"], article_url: page["fullurl"], monthly_views: views,
        image: (page["pageimage"] if image), image_url: (page["thumbnail"]["source"] if image) }
    end
  end

  # { title:, article_url:, image_url:, file_url:, credit: }, or nil when the
  # nearby area has no free photo.
  def self.photo_near(latitude, longitude, connection: nil, cache: Rails.cache)
    connection ||= SearchHttp.connection(API_URL)
    area = nearby_area(latitude, longitude, connection: connection, cache: cache)
    return unless area&.dig(:image)

    credit = cache.fetch("wikipedia:credit:v1:#{area[:image]}", expires_in: CREDIT_CACHE_TTL) do
      credit(area[:image], connection)
    end
    credit && area.slice(:title, :article_url, :image_url).merge(credit)
  end

  def self.nearest_natural_page(latitude, longitude, connection)
    pages = query(connection,
      generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: RADIUS_METERS, ggslimit: 20,
      prop: "pageimages|coordinates|info|pageviews|description", piprop: "thumbnail|name", pithumbsize: THUMBNAIL_WIDTH,
      pilicense: "free", inprop: "url", colimit: "max", pvipdays: VIEW_DAYS)
    pages.select { |page| natural?(page) }.min_by do |page|
      point = page["coordinates"].first
      OverpassService.distance(latitude, longitude, point["lat"], point["lon"])
    end
  end

  # { file_url:, credit: }, or nil when the image has no license to credit.
  def self.credit(image, connection)
    file = query(connection,
      titles: "File:#{image}", prop: "imageinfo", iiprop: "extmetadata|url",
      iiextmetadatafilter: "Artist|LicenseShortName").first
    file_url = value_at(file, "imageinfo", 0, "descriptionurl")
    license = value_at(file, "imageinfo", 0, "extmetadata", "LicenseShortName", "value")
    return unless license.is_a?(String) && license.strip.present? && wikimedia_url?(file_url)

    author = value_at(file, "imageinfo", 0, "extmetadata", "Artist", "value")
    author = Nokogiri::HTML5.fragment(author).text.squish.truncate(60) if author.is_a?(String)
    { file_url: file_url, credit: [author.presence, license.strip].compact.join(" · ") }
  end

  # Like dig, but returns nil instead of raising when the JSON has another shape.
  def self.value_at(node, *path)
    path.reduce(node) do |current, key|
      case current
      when Hash then current[key]
      when Array then key.is_a?(Integer) ? current[key] : nil
      end
    end
  end

  def self.query(connection, **params)
    data = SearchHttp.json do
      connection.get { |request| request.params = { action: "query", format: "json", formatversion: 2, **params } }
    end
    pages = data["query"]["pages"] if data["query"].is_a?(Hash)
    pages.is_a?(Array) ? pages.select { |page| page.is_a?(Hash) } : []
  end

  # Short descriptions such as "Park in Seattle" or "Heritage streetcar in Washington"
  # tell natural areas apart better than titles, which are used when there is none.
  def self.natural?(page)
    title, description = page.values_at("title", "description")
    kind = description.is_a?(String) && description.strip.present? ? description : title
    point = page["coordinates"].first if page["coordinates"].is_a?(Array)
    title.is_a?(String) && kind.match?(NATURAL) && !kind.match?(BUILT) && !title.match?(BUILT) &&
      wikipedia_url?(page["fullurl"]) && point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
  end

  def self.wikimedia_url?(url)
    uri = URI.parse(url) if url.is_a?(String)
    uri.is_a?(URI::HTTPS) && uri.host.to_s.end_with?(".wikimedia.org")
  rescue URI::InvalidURIError
    false
  end

  def self.wikipedia_url?(url)
    uri = URI.parse(url) if url.is_a?(String)
    uri.is_a?(URI::HTTPS) && uri.host == "en.wikipedia.org"
  rescue URI::InvalidURIError
    false
  end
end
