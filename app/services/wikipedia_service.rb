# Photos for route cards: the lead image of the nearest Wikipedia article about
# a park or natural area. Wikipedia serves these free images from Wikimedia
# Commons, and their licenses require crediting the author.
module WikipediaService
  API_URL = "https://en.wikipedia.org/w/api.php"
  RADIUS_METERS = 2_000
  THUMBNAIL_WIDTH = 500
  CACHE_TTL = 7.days
  NATURAL = /\b(?:parks?|trails?|lakes?|mount(?:ain)?s?|forests?|creeks?|falls|preserve|reserve|natural area|wilderness|peaks?|rivers?|beach(?:es)?|woods|gardens?|arboretum|canyons?|ridges?|hills?|bay|ponds?|marsh|wetlands?|greenway|valley|islands?|glacier|nature)\b/i
  BUILT = /\b(?:schools?|station|university|college|church|hospital|airport|mall|stadium|library|museum|company|corporation|district|building|tower|bridge|hotel|apartments?|condominiums?|highway|interchange|railway|railroad|zoo|cemetery|memorial|monument)\b/i

  # { title:, article_url:, image_url:, file_url:, credit: }, or nil when no
  # nearby natural area has a free photo.
  def self.photo_near(latitude, longitude, connection: nil, cache: Rails.cache)
    cache.fetch("wikipedia:photo:v1:#{latitude.round(3)}:#{longitude.round(3)}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(API_URL)
      page = nearest_natural_page(latitude, longitude, connection)
      photo(page, connection) if page
    end
  end

  def self.nearest_natural_page(latitude, longitude, connection)
    pages = query(connection,
      generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: RADIUS_METERS, ggslimit: 20,
      prop: "pageimages|coordinates|info", piprop: "thumbnail|name", pithumbsize: THUMBNAIL_WIDTH,
      pilicense: "free", inprop: "url")
    pages.select { |page| natural?(page) }.min_by do |page|
      point = page["coordinates"].first
      OverpassService.distance(latitude, longitude, point["lat"], point["lon"])
    end
  end

  def self.photo(page, connection)
    file = query(connection,
      titles: "File:#{page['pageimage']}", prop: "imageinfo", iiprop: "extmetadata|url",
      iiextmetadatafilter: "Artist|LicenseShortName").first
    file_url = value_at(file, "imageinfo", 0, "descriptionurl")
    license = value_at(file, "imageinfo", 0, "extmetadata", "LicenseShortName", "value")
    # Without a license the photo cannot be credited, so leave it out.
    return unless license.is_a?(String) && license.strip.present? && wikimedia_url?(file_url)

    author = value_at(file, "imageinfo", 0, "extmetadata", "Artist", "value")
    author = Nokogiri::HTML5.fragment(author).text.squish.truncate(60) if author.is_a?(String)
    {
      title: page["title"], article_url: page["fullurl"], image_url: page["thumbnail"]["source"],
      file_url: file_url, credit: [author.presence, license.strip].compact.join(" · ")
    }
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

  def self.natural?(page)
    title = page["title"]
    point = page["coordinates"].first if page["coordinates"].is_a?(Array)
    title.is_a?(String) && title.match?(NATURAL) && !title.match?(BUILT) &&
      page["pageimage"].is_a?(String) && page["thumbnail"].is_a?(Hash) &&
      wikimedia_url?(page["thumbnail"]["source"]) && wikipedia_url?(page["fullurl"]) &&
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
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
