# Photos of the scenery near a route, served from Wikimedia Commons under free
# licenses that require crediting the author: the lead image of the nearest
# Wikipedia article about a park or natural area, then photos taken nearby.
module WikipediaService
  API_URL = "https://en.wikipedia.org/w/api.php"
  COMMONS_URL = "https://commons.wikimedia.org/w/api.php"
  RADIUS_METERS = 2_000
  THUMBNAIL_WIDTH = 500
  CACHE_TTL = 7.days
  CREDIT_CACHE_TTL = 30.days
  MAX_PHOTOS = 8
  # Photos smaller than this, or wider than this many times their height, don't show the scenery well.
  MIN_PHOTO_WIDTH = 800
  MAX_ASPECT = 3
  # Titles of files near a route that aren't of its scenery, and of the ones that likely are.
  NOT_SCENERY = /\b(?:maps?|logos?|diagrams?|signs?|signposts?|plaques?|seals?|flags?|coat of arms|charts?|graphs?|locator|stamps?|collections?|bldg|buildings?|offices?|schools?|hospitals?|churche?s?|hotels?|motels?|lodges?|restaurants?|museums?|stations?|parking|town hall|city hall|village hall|courthouses?|post offices?|librar(?:y|ies)|stores?|shops?|diners?|caf[eé]s?|pubs?|vehicles?|motorcycles?|interiors?|portraits?|paintings?|drawings?|engravings?|lithographs?|postcards?|posters?|documents?|cars?|trucks?|buses)\b/i
  SCENERY = /\b(?:views?|vistas?|overlooks?|lookouts?|lakes?|ponds?|reservoirs?|rivers?|falls|waterfalls?|mountains?|mount|mt|hills?|ridges?|trails?|summits?|peaks?|forests?|woods|panorama|autumn|foliage|creeks?|brooks?|gorges?|cliffs?|rocks?|sunsets?|sunrises?|landscapes?|hik(?:e|es|ing)|preserve|reservation|valleys?|meadows?|beach|shore|state park)\b/i
  # Inns named for a place, as in "Bear Mountain Inn", but not the river Inn, as in
  # "Inn in Samedan", "Madulain - Inn", or "Blick auf den Inn".
  HOTEL_INN = /(?<=\w )(?<!der |des |den |dem |am |im |river )inns?\b(?! river| valley)/i
  # Photos of cars, named for their model year and make, as in "2015 Ford Explorer".
  VEHICLE = /\b(?:19|20)\d\d (?:Acura|Audi|BMW|Buick|Cadillac|Chevrolet|Chrysler|Dodge|Fiat|Ford|GMC|Honda|Hyundai|Infiniti|Jaguar|Jeep|Kia|Land Rover|Lexus|Lincoln|Mazda|Mercedes|Mini|Mitsubishi|Nissan|Pontiac|Porsche|Ram|Range Rover|Saturn|Scion|Subaru|Suzuki|Tesla|Toyota|Volkswagen|Volvo)\b/i
  # Uploads from nature-observation apps, named for the species and an observation number.
  SPECIES = /\A[A-Z][a-z]+ [a-z]+(?: [a-z]+)? \d{5,}\.jpe?g\z/
  NOT_SCENERY_TITLES = [NOT_SCENERY, HOTEL_INN, VEHICLE, SPECIES].freeze
  NATURAL = /\b(?:parks?|trails?|lakes?|mount(?:ain)?s?|forests?|creeks?|falls|waterfalls?|preserve|reserve|natural area|wilderness|peaks?|summits?|rivers?|beach(?:es)?|woods|gardens?|arboretum|canyons?|gorge|ridges?|hills?|bay|ponds?|marsh|wetlands?|greenway|valley|islands?|glacier|nature|headland|cape|bluffs?|cliffs?|dunes?|meadows?|prairie)\b/i
  # Short descriptions name the kind of thing first, as in "Fort on the Hudson River", then where it is.
  # "Of" is left in, since it's often part of the kind, as in "Range of hills" or "Tributary of the Wallkill River".
  DESCRIPTION_PLACE = /\s(?:in|on|at|near|along|within|during|between|from|by|off|outside|overlooking)\s.*/im
  # Places people live, as in "Mountain village" or "Suburb of Blue Mountains", aren't natural areas.
  SETTLEMENT = /\b(?:suburbs?|towns?|townships?|villages?|hamlets?|settlements?|communit(?:y|ies)|neighbou?rhoods?)\b/i
  BUILT = /\b(?:schools?|station|university|college|church|hospital|airport|mall|stadium|library|museum|company|corporation|district|building|tower|bridge|hotel|apartments?|condominiums?|highway|interchange|railway|railroad|zoo|cemetery|memorial|monument)\b/i

  # { title:, article_url:, image:, image_url: }, or nil when no park or
  # natural area is nearby; image is nil when its article has no free one.
  def self.nearby_area(latitude, longitude, connection: nil, cache: Rails.cache)
    # Routes joined within about 1 km of each other share one lookup.
    latitude, longitude = latitude.round(2), longitude.round(2)
    cache.fetch("wikipedia:area:v3:#{latitude}:#{longitude}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(API_URL)
      page = nearest_natural_page(latitude, longitude, connection)
      next unless page

      image = page["pageimage"].is_a?(String) && wikimedia_url?(value_at(page, "thumbnail", "source"))
      { title: page["title"], article_url: page["fullurl"],
        image: (page["pageimage"] if image), image_url: (page["thumbnail"]["source"] if image) }
    end
  end

  # Photos of the scenery near a point, as { title:, article_url:, photos:
  # [{ image_url:, file_url:, credit:, caption: }] } with the nearest park or
  # natural area's title and article (nil when there is none) and up to
  # MAX_PHOTOS photos: its lead image, then photos taken nearby, scenery first.
  # nil when there are none.
  def self.photos_near(latitude, longitude, connection: nil, commons: nil, cache: Rails.cache)
    connection ||= SearchHttp.connection(API_URL)
    area = nearby_area(latitude, longitude, connection: connection, cache: cache)
    lead = if area&.dig(:image)
      credit = cache.fetch("wikipedia:credit:v2:#{area[:image]}", expires_in: CREDIT_CACHE_TTL) { credit(area[:image], connection) }
      { image_url: area[:image_url], caption: "Near #{area[:title]}" }.merge(credit) if credit
    end
    photos = [lead, *commons_photos(latitude, longitude, commons, cache)].compact
      .uniq { |photo| photo[:file_url] }.first(MAX_PHOTOS)
    { title: area&.dig(:title), article_url: area&.dig(:article_url), photos: photos } if photos.any?
  end

  # Credited photos taken within RADIUS_METERS of a point, on Wikimedia
  # Commons, leaving out maps, signs, buildings, cars, and close-ups of species.
  def self.commons_photos(latitude, longitude, connection, cache)
    latitude, longitude = latitude.round(2), longitude.round(2)
    cache.fetch("wikipedia:commons:v2:#{latitude}:#{longitude}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(COMMONS_URL)
      files = query(connection,
        generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: RADIUS_METERS, ggsnamespace: 6,
        ggslimit: 40, prop: "imageinfo|coordinates", iiprop: "url|extmetadata|mime|size", iiurlwidth: THUMBNAIL_WIDTH,
        iiextmetadatafilter: "Artist|LicenseShortName", colimit: "max")
      files.filter_map { |file| commons_photo(file, latitude, longitude) }
        .sort_by { |photo| [photo[:scenery] ? 0 : 1, photo[:meters]] }.first(MAX_PHOTOS)
        .map { |photo| photo.except(:scenery, :meters) }
    end
  end

  def self.commons_photo(file, latitude, longitude)
    title = file["title"].delete_prefix("File:") if file["title"].is_a?(String)
    info = value_at(file, "imageinfo", 0)
    point = value_at(file, "coordinates", 0)
    return unless title && info.is_a?(Hash) && info["mime"] == "image/jpeg" &&
      NOT_SCENERY_TITLES.none? { |pattern| title.match?(pattern) } && info["width"].is_a?(Integer) && info["height"].is_a?(Integer) &&
      info["width"] >= MIN_PHOTO_WIDTH && info["height"].positive? && info["width"] <= info["height"] * MAX_ASPECT &&
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"]) &&
      wikimedia_url?(info["thumburl"]) && wikimedia_url?(info["descriptionurl"])

    credit = credit_from(info)
    return unless credit

    caption = title.sub(/\.jpe?g\z/i, "").tr("_", " ").squish.truncate(80)
    { image_url: info["thumburl"], file_url: info["descriptionurl"], credit: credit, caption: caption,
      scenery: caption.match?(SCENERY), meters: OverpassService.distance(latitude, longitude, point["lat"], point["lon"]) }
  end

  def self.nearest_natural_page(latitude, longitude, connection)
    pages = query(connection,
      generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: RADIUS_METERS, ggslimit: 20,
      prop: "pageimages|coordinates|info|description", piprop: "thumbnail|name", pithumbsize: THUMBNAIL_WIDTH,
      pilicense: "free", inprop: "url", colimit: "max")
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
    info = value_at(file, "imageinfo", 0)
    credit = credit_from(info) if info.is_a?(Hash)
    { file_url: info["descriptionurl"], credit: credit } if credit
  end

  # "Author · License" for a file's image info, or nil when it has no license to credit.
  def self.credit_from(info)
    license = value_at(info, "extmetadata", "LicenseShortName", "value")
    return unless license.is_a?(String) && license.strip.present? && wikimedia_url?(info["descriptionurl"])

    author = value_at(info, "extmetadata", "Artist", "value")
    if author.is_a?(String)
      html = Nokogiri::HTML5.fragment(author)
      # Commons repeats some names in hidden elements for machine readers.
      html.css("[style]").each { |node| node.remove if node["style"].match?(/display\s*:\s*none/i) }
      author = html.text.squish.truncate(60)
    end
    [author.presence, license.strip].compact.join(" · ")
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
  # Only the kind of thing counts, not where it is, so a fort on a river isn't a natural area.
  def self.natural?(page)
    title, description = page.values_at("title", "description")
    point = page["coordinates"].first if page["coordinates"].is_a?(Array)
    return false unless title.is_a?(String) && !title.match?(BUILT) && wikipedia_url?(page["fullurl"]) &&
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
    return title.match?(NATURAL) unless description.is_a?(String) && description.strip.present?

    kind = description.sub(DESCRIPTION_PLACE, "")
    kind.match?(NATURAL) && !kind.match?(BUILT) && !kind.match?(SETTLEMENT)
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
