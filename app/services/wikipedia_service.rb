# Photos of nature along a route, served from Wikimedia Commons under free
# licenses that require crediting the author: the lead image of the nearest
# Wikipedia article about a park or natural area, then photos taken along it.
module WikipediaService
  API_URL = "https://en.wikipedia.org/w/api.php"
  COMMONS_URL = "https://commons.wikimedia.org/w/api.php"
  RADIUS_METERS = 2_000
  # Big parks' articles are placed at their middle, so the nearest park is looked for farther out.
  AREA_RADIUS_METERS = 5_000
  THUMBNAIL_WIDTH = 500
  # Commons answers queries about many files slowly, and Wikipedia a little faster.
  COMMONS_TIMEOUT_SECONDS = 20
  API_TIMEOUT_SECONDS = 10
  # A route's photos are looked for for at most this long altogether, so a slow
  # Commons doesn't hold up the server; guide builds, which can wait, pass longer.
  LOOKUP_SECONDS = 15
  # Answers continued for more categories are followed this many times at most.
  MAX_CONTINUES = 10
  CACHE_TTL = 7.days
  CREDIT_CACHE_TTL = 30.days
  MAX_PHOTOS = 8
  # Photos in a series, such as "Sugarloaf Mountain in summer 2" and "3", look alike, so few of each are shown.
  MAX_PER_SERIES = 2
  # Commons is asked for the sizes of this many files near each point, then for
  # the credits and categories of the nearest DETAILED_PER_POINT that could be
  # photos of the scenery, and each point keeps PHOTOS_PER_POINT photos. Near
  # towns, the nearest files are mostly of streets and buildings, and many are
  # too small to show the scenery.
  FILES_PER_POINT = 200
  DETAILED_PER_POINT = 50
  PHOTOS_PER_POINT = 16
  # Photos smaller than this, or wider than this many times their height, don't show the scenery well.
  MIN_PHOTO_WIDTH = 800
  MAX_ASPECT = 3
  # Photos are of nature when their title or a Commons category names a natural feature...
  NATURE = /\b(?:mountains?|mount|mt|hills?|ridges?|peaks?|summits?|cliffs?|bluffs?|ledges?|rocks?|boulders?|knobs?|notch|gorges?|canyons?|ravines?|valleys?|glens?|highlands|palisades|escarpments?|lakes?|ponds?|reservoirs?|rivers?|creeks?|brooks?|streams?|kill|falls|waterfalls?|cascades?|rapids|shores?|coasts?|beach(?:es)?|islands?|marsh(?:es)?|swamps?|wetlands?|bogs?|forests?|woods|woodlands?|trees?|foliage|autumn|meadows?|grasslands?|prairies?|trails?|hik(?:e|es|ing)|hikers?|state parks?|national parks?|state forests?|preserves?|reservations?|wilderness|nature|landscapes?|scenery|overlooks?|lookouts?|glaciers?|alps?|piz)\b/i
  # ...and neither names anything built, vehicles, people, close-ups of wildlife, maps or artworks, or views from space.
  NOT_NATURE = /\b(?:buildings?|bldg|houses?|homes?|churche?s?|chapels?|temples?|synagogues?|mosques?|schools?|schoolhouses?|colleges?|universit(?:y|ies)|campus(?:es)?|hospitals?|offices?|halls?|courthouses?|post offices?|pavilions?|restrooms?|toilets?|cottages?|cabins?|sheds?|ruins?|furnaces?|cent(?:er|re)s?|historic (?:sites?|districts?)|national register of historic places|nrhp|condominiums?|apartments?|stations?|railways?|railroads?|rail(?!\s*trails?\b)|trains?|locomotives?|tracks|level crossings?|metro-north|lirr|nj transit|amtrak|septa|subways?|(?<!carriage )roads?|streets?|ave|avenues?|drives?|highways?|interstates? (?:\d+|highways?)|turnpikes?|parkways?|expressways?|(?:state|county|u\.?\s?s\.?|interstate) routes?|routes? \d+|interchanges?|exits?|intersections?|traffic|signs?|signposts?|shields?|markers?|plaques?|kiosks?|entrances?|gates?|fences?|bridges?|tunnels?|viaducts?|aqueducts?(?!\s+(?:trails?|state)\b)|dams?|piers?|docks?|marinas?|harbou?rs?|boathouses?|cars?|vehicles?|trucks?|buses|motorcycles?|bicycles?|aircraft|airplanes?|helicopters?|ships?|boats?|barges?|tugboats?|vessels?|ferr(?:y|ies)|construction|equipment|machinery|downtown|main street|neighbou?rhoods?|skylines?|cityscapes?|urban|aerial|hotels?|motels?|lodges?|restaurants?|shops?|stores?|malls?|markets?|diners?|caf[eé]s?|pubs?|museums?|galleries|librar(?:y|ies)|collections?|monuments?|memorials?|statues?|sculptures?|graves?|cemeter(?:y|ies)|forts?|castles?(?!\s+(?:point|rocks?|hills?|peaks?|crags?|mountains?))|mansions?|estates?|barns?|farms?|gardening|lighthouses?|towers?|power lines?|factor(?:y|ies)|grandstands?|racetracks?|stadiums?|playgrounds?|golf(?:ers?)?|pga|championships?|tournaments?|sports?|parking|inside|indoors?|interiors?|exhibits?|aquariums?|zoos?|hatcher(?:y|ies)|people|men|women|boys?|girls?|children|kids|portraits?|selfies?|given names?|surnames?|families|weddings?|politicians?|musicians?|actors?|actresses?|athletes?|players?|directors?|staff|employees?|volunteers?|rangers?|officials?|officers?|biologists?|scientists?|students?|workers?|crews?|visitors?|tourists?|hunters?|anglers?|fishermen|soldiers?|military|army|police|firefighters?|events?|celebrat(?:es?|ed|ing|ions?)|anniversar(?:y|ies)|awards?|receiving|dedications?|secretar(?:y|ies)|friends|damage|hurricanes?|disasters?|parades?|festivals?|concerts?|protests?|press conferences?|ceremon(?:y|ies)|animals?|wildlife(?!\s+(?:refuges?|management|sanctuar(?:y|ies)|preserves?))|birds?(?!\s+(?:sanctuar(?:y|ies)|refuges?))|mammals?|reptiles?|amphibians?|insects?|butterfl(?:y|ies)|moths?|spiders?|fungi|mushrooms?|lichens?|fauna|flora|flowers|wildflowers|inaturalist|unidentified|(?:turtles|snakes|frogs|toads|salamanders|deer|foxes|squirrels|beavers|owls|hawks|eagles|herons|egrets|ducks|geese|swans|woodpeckers|warblers|dragonflies|bees|beetles) (?:of|in)|maps?|diagrams?|logos?|flags?|seals?|coats? of arms|charts?|graphs?|locator|stamps?|documents?|postcards?|posters?|paintings?|drawings?|engravings?|lithographs?|prints?|stereo|albumen|illustrations?|films?|fortifications?|mapillary|wiki loves monuments|wlm|astronauts?|iss \d+|of earth|satellites?)\b/i
  # Taxonomic names mark close-ups of wildlife: families, as in "Parulidae", and species, as in
  # "Setophaga virens", "Cyanocitta cristata bromia", or "Phytolacca americana in July".
  FAMILY = /\b[A-Z][a-z]+(?:idae|aceae)\b/
  # Species named in parentheses, as in "Serviceberry (Amelanchier sp.)" or "Snapping Turtle (Chelydra serpentina)".
  SPECIES_NOTE = /\([A-Z][a-z]+ (?:[a-z]+|spp?\.)\)/
  # Clouds have Latin names too, as in "Cumulus humilis", and are skies over landscapes.
  SPECIES_NAME = /\A(?!(?:Cirro|Alto|Strato|Nimbo)?(?:[Cc]umulus|[Ss]tratus)\b|Cirrus\b|Cumulonimbus\b)[A-Z][a-z]+ [a-z]+(?:a|ae|i|is|us|um|ens|ans|ex|ix)(?: [a-z]+)?(?: (?:in|at|on|from) .+)?\z/
  # Artworks, named for their artist, as in "Alexander Hamilton by Franklin Simmons", unlike "Photographs by ..." or "Trees damaged by fire".
  ARTWORK = /\A(?!(?i:photo(?:graph)?s|images|pictures|media|files|uploads)\b).+ by [[:upper:]][[:alpha:]]+(?: [[:upper:]][[:alpha:].]*)+\z/
  # Train lines, as in "Hudson Line" or "Danbury Branch", but not rivers, as in "South Branch Raritan River",
  # or state lines, as in "State Line Lookout".
  RAIL_LINE = /\b(?!State\b)[A-Z][\w-]* (?:Line|Branch)\b(?!(?: [A-Z][\w-]*)* (?:River|Creek|Brook|Kill|Run)\b)/
  # Inns named for a place, as in "Bear Mountain Inn", but not the river Inn, as in
  # "Inn in Samedan", "Madulain - Inn", or "Blick auf den Inn".
  HOTEL_INN = /(?<=\w )(?<!der |des |den |dem |am |im |river )inns?\b(?! river| valley)/i
  # Photos of cars, named for their model year and make, as in "2015 Ford Explorer".
  VEHICLE = /\b(?:19|20)\d\d (?:Acura|Audi|BMW|Buick|Cadillac|Chevrolet|Chrysler|Dodge|Fiat|Ford|GMC|Honda|Hyundai|Infiniti|Jaguar|Jeep|Kia|Land Rover|Lexus|Lincoln|Mazda|Mercedes|Mini|Mitsubishi|Nissan|Pontiac|Porsche|Ram|Range Rover|Saturn|Scion|Subaru|Suzuki|Tesla|Toyota|Volkswagen|Volvo)\b/i
  # Uploads from nature-observation apps, named for the species and an observation number.
  SPECIES = /\A[A-Z][a-z]+ [a-z]+(?: [a-z]+)? \d{5,}\.jpe?g\z/
  # Places named for nature, as in "Cold Spring, New York" or "Long Island", aren't nature.
  PLACE = /\A[^,]+, [^,]+\z/
  URBAN_ISLAND = /\b(?:long|staten|rhode|coney|roosevelt|city|randalls|governors|ellis|liberty) island\b/i
  # Views and waterfalls lead the photos.
  SCENERY = /\b(?:views?|vistas?|overlooks?|lookouts?|panoramas?|landscapes?|scenery|summits?|peaks?|waterfalls?|falls)\b/i
  NATURAL = /\b(?:parks?|trails?|lakes?|mount(?:ain)?s?|forests?|creeks?|falls|waterfalls?|preserve|reserve|natural area|wilderness|peaks?|summits?|rivers?|beach(?:es)?|woods|gardens?|arboretum|canyons?|gorge|ridges?|hills?|bay|ponds?|marsh|wetlands?|greenway|valley|islands?|glacier|nature|headland|cape|bluffs?|cliffs?|dunes?|meadows?|prairie)\b/i
  # Short descriptions name the kind of thing first, as in "Fort on the Hudson River", then where it is.
  # "Of" is left in, since it's often part of the kind, as in "Range of hills" or "Tributary of the Wallkill River".
  DESCRIPTION_PLACE = /\s(?:in|on|at|near|along|within|during|between|from|by|off|outside|overlooking|across|over|under|through|around|beside|above|below)\s.*/im
  # Places people live, as in "Mountain village" or "Suburb of Blue Mountains", aren't natural areas.
  SETTLEMENT = /\b(?:suburbs?|towns?|townships?|villages?|hamlets?|settlements?|communit(?:y|ies)|neighbou?rhoods?)\b/i
  BUILT = /\b(?:schools?|station|university|college|church|hospital|airport|mall|stadium|library|museum|company|corporation|district|building|tower|bridge|hotel|apartments?|condominiums?|highway|interchange|railway|railroad|zoo|cemetery|memorial|monument|houses?|castles?(?!\s+(?:point|rocks?|hills?|peaks?|crags?|mountains?))|palaces?|manors?|mansions?)\b/i

  # { title:, article_url:, image:, image_url: }, or nil when no park or
  # natural area is nearby; image is nil when its article has no free one.
  def self.nearby_area(latitude, longitude, connection: nil, cache: Rails.cache, deadline: nil)
    # Routes joined within about 1 km of each other share one lookup.
    latitude, longitude = latitude.round(2), longitude.round(2)
    cache.fetch("wikipedia:area:v4:#{latitude}:#{longitude}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(API_URL, timeout: API_TIMEOUT_SECONDS)
      page = nearest_natural_page(latitude, longitude, connection, deadline)
      next unless page

      image = page["pageimage"].is_a?(String) && wikimedia_url?(value_at(page, "thumbnail", "source"))
      { title: page["title"], article_url: page["fullurl"],
        image: (page["pageimage"] if image), image_url: (page["thumbnail"]["source"] if image) }
    end
  end

  # Photos of nature along a route, as { title:, article_url:, photos: [{
  # image_url:, file_url:, credit:, caption: }] } with the nearest park or
  # natural area's title and article (nil when there is none) and up to
  # MAX_PHOTOS photos: its lead image, then photos taken within RADIUS_METERS
  # of the points, [latitude, longitude] pairs along the route with its middle
  # first, views and waterfalls first and then the nearest. nil when there are
  # none. A lookup that fails only leaves out its photos, unless there are none
  # at all, when it raises. Lookups stop after timeout seconds altogether.
  def self.photos_near(points, connection: nil, commons: nil, cache: Rails.cache, timeout: LOOKUP_SECONDS)
    connection ||= SearchHttp.connection(API_URL, timeout: API_TIMEOUT_SECONDS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    errors = []
    area = surviving(errors) { nearby_area(*points.first, connection: connection, cache: cache, deadline: deadline) }
    lead = surviving(errors) { lead_photo(area, connection, cache, deadline) }
    taken = points.flat_map do |latitude, longitude|
      surviving(errors) { commons_photos(latitude, longitude, commons, cache, deadline) } || []
    end
      .sort_by { |photo| [photo[:scenery] ? 0 : 1, photo[:meters]] }
    shown = Hash.new(0)
    photos = [lead, *taken].compact.uniq { |photo| photo[:file_url] }
      .select { |photo| (shown[series(photo[:caption])] += 1) <= MAX_PER_SERIES }
      .first(MAX_PHOTOS).map { |photo| photo.except(:scenery, :meters) }
    raise errors.first if photos.empty? && errors.any?

    { title: area&.dig(:title), article_url: area&.dig(:article_url), photos: photos } if photos.any?
  end

  # The block's value, or nil when its lookup fails, noting the failure.
  def self.surviving(errors)
    yield
  rescue SearchErrors::UpstreamError => error
    errors << error
    nil
  end

  # The lead image of the park or natural area's article, when it's a photo of nature.
  def self.lead_photo(area, connection, cache, deadline = nil)
    return unless area&.dig(:image)

    file = cache.fetch("wikipedia:lead:v1:#{area[:image]}", expires_in: CREDIT_CACHE_TTL) do
      lead_file(area[:image], connection, deadline)
    end
    return unless file && nature?(caption(area[:image]), file[:categories])

    { image_url: area[:image_url], caption: "Near #{area[:title]}", file_url: file[:file_url], credit: file[:credit] }
  end

  # Credited photos of nature taken within RADIUS_METERS of a point, on
  # Wikimedia Commons, with how far away each was taken and whether it's of a
  # view or waterfall. Each point's photos are shared by routes within about 1 km.
  def self.commons_photos(latitude, longitude, connection, cache, deadline = nil)
    latitude, longitude = latitude.round(2), longitude.round(2)
    cache.fetch("wikipedia:commons:v4:#{latitude}:#{longitude}", expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(COMMONS_URL, timeout: COMMONS_TIMEOUT_SECONDS)
      # Which files nearby could be photos of the scenery, by their type and size...
      sized = query(connection, deadline: deadline,
        generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: RADIUS_METERS, ggsnamespace: 6,
        ggslimit: FILES_PER_POINT, prop: "imageinfo|coordinates", iiprop: "mime|size", colimit: "max")
        .select { |file| file["pageid"].is_a?(Integer) && photo_sized?(file) }
        .min_by(DETAILED_PER_POINT) { |file| meters_from(file, latitude, longitude) }
      next [] if sized.empty?

      # ...then the nearest of those, with their credits and categories.
      files = query(connection, deadline: deadline,
        pageids: sized.map { |file| file["pageid"] }.join("|"), prop: "imageinfo|coordinates|categories",
        iiprop: "url|extmetadata|mime|size", iiurlwidth: THUMBNAIL_WIDTH, iiextmetadatafilter: "Artist|LicenseShortName",
        colimit: "max", clshow: "!hidden", cllimit: "max")
      files.filter_map { |file| commons_photo(file, latitude, longitude) }
        .sort_by { |photo| [photo[:scenery] ? 0 : 1, photo[:meters]] }.first(PHOTOS_PER_POINT)
    end
  end

  # Whether a file is a JPEG big enough, and not too wide, to show the scenery.
  def self.photo_sized?(file)
    info = value_at(file, "imageinfo", 0)
    info.is_a?(Hash) && info["mime"] == "image/jpeg" && info["width"].is_a?(Integer) && info["height"].is_a?(Integer) &&
      info["width"] >= MIN_PHOTO_WIDTH && info["height"].positive? && info["width"] <= info["height"] * MAX_ASPECT
  end

  def self.meters_from(file, latitude, longitude)
    point = value_at(file, "coordinates", 0)
    return Float::INFINITY unless point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])

    OverpassService.distance(latitude, longitude, point["lat"], point["lon"])
  end

  def self.commons_photo(file, latitude, longitude)
    title = file["title"].delete_prefix("File:") if file["title"].is_a?(String)
    info = value_at(file, "imageinfo", 0)
    point = value_at(file, "coordinates", 0)
    return unless title && photo_sized?(file) && !title.match?(SPECIES) &&
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"]) &&
      wikimedia_url?(info["thumburl"]) && wikimedia_url?(info["descriptionurl"])

    caption, categories = caption(title), categories(file)
    credit = credit_from(info)
    return unless credit && nature?(caption, categories)

    { image_url: info["thumburl"], file_url: info["descriptionurl"], credit: credit, caption: caption.truncate(80),
      scenery: [caption, *categories].any? { |text| text.match?(SCENERY) },
      meters: OverpassService.distance(latitude, longitude, point["lat"], point["lon"]) }
  end

  # Whether a photo is of nature: its title or a category names a natural
  # feature, and neither names anything built, vehicles, people, close-ups of
  # wildlife, maps or artworks.
  def self.nature?(caption, categories)
    texts = [caption, *categories]
    texts.none? { |text| unnatural?(text) } && texts.any? { |text| natural_name?(text) }
  end

  def self.unnatural?(text)
    words = spaced(text)
    [NOT_NATURE, RAIL_LINE, HOTEL_INN, VEHICLE].any? { |pattern| words.match?(pattern) } ||
      text.match?(FAMILY) || text.match?(ARTWORK) || text.match?(SPECIES_NOTE) || (text.gsub(/\s*\([^)]*\)/, "").match?(SPECIES_NAME) && !text.match?(NATURE))
  end

  # Words apart from the numbers they run into, as "Bethpage-golf1" names golf.
  def self.spaced(text)
    text.gsub(/(?<=[[:alpha:]])(?=[[:digit:]])|(?<=[[:digit:]])(?=[[:alpha:]])/, " ")
  end

  # Names a natural feature, and isn't a place named for one, as "Cold Spring, New York" or "Long Island" are.
  def self.natural_name?(text)
    name = spaced(without_places(text)).gsub(URBAN_ISLAND, "").squish
    !name.match?(PLACE) && name.match?(NATURE)
  end

  # A name without the places and numbers in parentheses, as in "Bear Mountain (New York)" or
  # "Harriman (6020446359)", which keeps kinds, as in "Inn (river)", or an upload site, as in "Lake - panoramio".
  def self.without_places(text)
    text.gsub(/\s*\((?=[[:upper:][:digit:]])[^)]*\)/, "").sub(/\s+-\s+panoramio\z/i, "")
  end

  # The title of a series of photos, such as "Sugarloaf Mountain in summer" for "... in summer 2" and "... 3",
  # or "Grimm Forest" for "Grimm Forest I" and "Grimm Forest II - Letterboxing".
  def self.series(caption)
    name = caption.split(/\s+[-–]\s+/).first.to_s.sub(/[\s\-–_]*\(?\d[\d\s\-–_()]*[[:alpha:]]?\)?\z/, "")
    without_places(name).sub(/\s+[IVX]+\z/, "").downcase.presence || caption.downcase
  end

  def self.caption(title)
    title.sub(/\.jpe?g\z/i, "").tr("_", " ").squish
  end

  # A Commons file's visible categories, without "Category:".
  def self.categories(file)
    Array(value_at(file, "categories")).filter_map do |category|
      category["title"].delete_prefix("Category:") if category.is_a?(Hash) && category["title"].is_a?(String)
    end
  end

  def self.nearest_natural_page(latitude, longitude, connection, deadline = nil)
    pages = query(connection, deadline: deadline,
      generator: "geosearch", ggscoord: "#{latitude}|#{longitude}", ggsradius: AREA_RADIUS_METERS, ggslimit: 50,
      prop: "pageimages|coordinates|info|description", piprop: "thumbnail|name", pithumbsize: THUMBNAIL_WIDTH,
      pilicense: "free", inprop: "url", colimit: "max")
    pages.select { |page| natural?(page) }.min_by do |page|
      point = page["coordinates"].first
      OverpassService.distance(latitude, longitude, point["lat"], point["lon"])
    end
  end

  # { file_url:, credit:, categories: } for a lead image that's a photo with a license to credit, or nil.
  def self.lead_file(image, connection, deadline = nil)
    file = query(connection, deadline: deadline,
      titles: "File:#{image}", prop: "imageinfo|categories", iiprop: "extmetadata|url|mime",
      iiextmetadatafilter: "Artist|LicenseShortName", clshow: "!hidden", cllimit: "max").first
    info = value_at(file, "imageinfo", 0)
    credit = credit_from(info) if info.is_a?(Hash) && info["mime"] == "image/jpeg"
    { file_url: info["descriptionurl"], credit: credit, categories: categories(file) } if credit
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

  # The pages a query finds. Answers are continued when a page's categories don't
  # all fit, and the rest are added to its page, so none goes unchecked. With a
  # deadline, requests only wait for the time left, and none is made after it.
  def self.query(connection, deadline: nil, **params)
    pages, continued = {}, {}
    MAX_CONTINUES.times do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) if deadline
      raise SearchErrors::UpstreamError, SearchHttp::UNAVAILABLE_MESSAGE if left && left <= 0

      data = SearchHttp.json do
        connection.get do |request|
          request.params = { action: "query", format: "json", formatversion: 2, **params, **continued }
          if left
            request.options.timeout = [request.options.timeout, left].compact.min
            request.options.open_timeout = [request.options.open_timeout, left].compact.min
          end
        end
      end
      found = data["query"]["pages"] if data["query"].is_a?(Hash)
      Array(found).each do |page|
        next unless page.is_a?(Hash)

        merged = pages[page["pageid"] || page["title"]] ||= page
        next if merged.equal?(page)

        merged["categories"] = Array(merged["categories"]) + Array(page["categories"])
        page.each { |key, value| merged[key] = value unless merged.key?(key) }
      end
      break unless data["continue"].is_a?(Hash)

      continued = data["continue"].to_h { |key, value| [key.to_sym, value] }
    end
    pages.values
  end

  # Short descriptions such as "Park in Seattle" or "Heritage streetcar in Washington"
  # tell natural areas apart better than titles, which are used when there is none.
  # Only the kind of thing counts, not where it is, so a fort on a river isn't a natural area.
  def self.natural?(page)
    title, description = page.values_at("title", "description")
    point = page["coordinates"].first if page["coordinates"].is_a?(Array)
    return false unless title.is_a?(String) && !title.match?(BUILT) && wikipedia_url?(page["fullurl"]) &&
      point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lon"])
    return title.gsub(URBAN_ISLAND, "").match?(NATURAL) unless description.is_a?(String) && description.strip.present?

    kind = description.sub(DESCRIPTION_PLACE, "").gsub(URBAN_ISLAND, "")
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
