# Place search from Photon (https://photon.komoot.io), an OpenStreetMap geocoder
# built for search-as-you-type. Its public API asks clients to use it fairly.
module PhotonService
  URL = "https://photon.komoot.io/api/"
  REVERSE_URL = "https://photon.komoot.io/reverse"
  CACHE_TTL = 1.day
  # Where a point is doesn't change, so it's kept for a month, shared by points about a kilometer apart.
  LOCALITY_CACHE_TTL = 30.days
  # Great Britain's nations are too big to say where a place is, so their counties do.
  NATIONS = ["England", "Scotland", "Wales", "Northern Ireland"].freeze
  MAX_SUGGESTIONS = 6
  # Transit stops and open water crowd out the places people actually start from.
  EXCLUDED_TAGS = %w[
    !highway:bus_stop !public_transport:platform !public_transport:stop_position !railway:platform
    !place:sea !place:ocean !natural:strait
  ].freeze

  # near is a rough [latitude, longitude] used only to rank nearby places first.
  def self.suggest(query, near: nil, connection: nil, cache: Rails.cache)
    bias = near&.map { |coordinate| coordinate.round(1) }
    key = "photon:v1:#{query.downcase.squish}:#{bias&.join(',')}"
    places = cache.fetch(key, expires_in: CACHE_TTL) do
      connection ||= SearchHttp.connection(URL)
      params = { q: query, limit: MAX_SUGGESTIONS + 4, lang: "en", osm_tag: EXCLUDED_TAGS }
      # A regional, moderate bias: well-known places elsewhere still show up.
      params.merge!(lat: bias[0], lon: bias[1], zoom: 5, location_bias_scale: 0.5) if bias
      data = SearchHttp.json do
        connection.get do |request|
          request.options.params_encoder = Faraday::FlatParamsEncoder
          request.params = params
        end
      end
      unless data["features"].is_a?(Array)
        raise SearchErrors::UpstreamError, "The location provider returned an invalid response."
      end

      data["features"].filter_map { |feature| place(feature) }.uniq { |place| place[:name] }.first(MAX_SUGGESTIONS)
    end
    places.map { |attributes| Place.new(**attributes) }
  end

  def self.geocode(query, **options)
    suggest(query, **options).first
  end

  # The town or city a point is in or nearest, its state or region, and its
  # country, as { locality:, region:, country: } in English, or nil when
  # nothing is mapped nearby. Raises when the lookup fails.
  def self.locality(latitude, longitude, connection: nil, cache: Rails.cache)
    found = cache.fetch("photon:locality:v1:#{latitude.round(2)}:#{longitude.round(2)}", expires_in: LOCALITY_CACHE_TTL) do
      connection ||= SearchHttp.connection(REVERSE_URL)
      data = SearchHttp.json do
        connection.get { |request| request.params = { lat: latitude.round(5), lon: longitude.round(5), lang: "en" } }
      end
      properties = Array(data["features"]).find { |feature| feature.is_a?(Hash) }&.dig("properties")
      # Nothing nearby is remembered too, as false.
      (properties.is_a?(Hash) && locality_of(properties)) || false
    end
    found || nil
  end

  def self.locality_of(properties)
    name = ->(key) { properties[key].squish.truncate(60) if properties[key].is_a?(String) && properties[key].strip.present? }
    state = name.("state")
    found = { locality: %w[city town village district county].filter_map(&name).first,
      region: NATIONS.include?(state) ? name.("county") : state, country: name.("country") }.compact
    found if found[:locality] || found[:region]
  end

  # The reference coordinates of an IANA time zone, e.g. Los Angeles for
  # "America/Los_Angeles": a rough, permission-free hint of where someone is.
  def self.zone_center(time_zone)
    return unless time_zone.is_a?(String) && time_zone.match?(TransitousService::TIME_ZONE_FORMAT)

    @zone_centers ||= TZInfo::Country.all.flat_map(&:zone_info)
      .to_h { |zone| [zone.identifier, [zone.latitude.to_f, zone.longitude.to_f]] }
    @zone_centers[time_zone]
  rescue TZInfo::DataSourceNotFound
    nil
  end

  def self.place(feature)
    return unless feature.is_a?(Hash) && feature["properties"].is_a?(Hash)

    longitude, latitude = feature.dig("geometry", "coordinates")
    name = label(feature["properties"])
    { name: name, latitude: latitude, longitude: longitude } if name && SearchHttp.coordinates?(latitude, longitude)
  end

  # For example "Pike Place Market, Seattle, Washington, United States".
  def self.label(properties)
    address = [properties["housenumber"], properties["street"]].grep(String).join(" ").presence
    parts = [properties["name"] || address, properties["city"], properties["state"], properties["country"]]
    parts.grep(String).map(&:strip).reject(&:empty?).uniq.join(", ").presence
  end
end
