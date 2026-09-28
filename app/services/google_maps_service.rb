require "time"
require "uri"

module GoogleMapsService
  GEOCODING_URL = "https://maps.googleapis.com/maps/api/geocode/json"
  ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
  Location = Struct.new(:latitude, :longitude, keyword_init: true)

  def self.api_key(environment: ENV, credentials: nil)
    key = environment["GOOGLE_MAPS_API_KEY"].presence
    return key if key

    credentials ||= Rails.application.credentials
    key = credentials.google_maps_key
    raise SearchErrors::UpstreamError, "Transit search is not configured. Please try again later." if key.blank?

    key
  rescue ActiveSupport::EncryptedFile::MissingKeyError, ActiveSupport::MessageEncryptor::InvalidMessage
    raise SearchErrors::UpstreamError, "Transit search is not configured. Please try again later."
  end

  def self.geocode(origin, connection: nil, key: api_key)
    connection ||= SearchHttp.connection(GEOCODING_URL)
    data = SearchHttp.json { connection.get { |request| request.params = { address: origin, key: key } } }
    unless data["results"].is_a?(Array)
      raise SearchErrors::UpstreamError, "The location provider returned an invalid response."
    end
    return nil if data["status"] == "ZERO_RESULTS" && data["results"].empty?
    unless data["status"] == "OK" && data["results"].first.is_a?(Hash)
      raise SearchErrors::UpstreamError, "The location provider is unavailable. Please try again later."
    end

    geometry = data["results"].first["geometry"]
    point = geometry.is_a?(Hash) ? geometry["location"] : nil
    unless point.is_a?(Hash) && SearchHttp.coordinates?(point["lat"], point["lng"])
      raise SearchErrors::UpstreamError, "The location provider returned invalid coordinates."
    end
    Location.new(latitude: point["lat"], longitude: point["lng"])
  end

  def self.transit_duration(origin:, destination:, arrival_time:, connection: nil, key: api_key)
    connection ||= SearchHttp.connection(ROUTES_URL)
    body = {
      origin: waypoint(origin), destination: waypoint(destination),
      travelMode: "TRANSIT", arrivalTime: arrival_time.utc.iso8601
    }
    data = SearchHttp.json do
      connection.post do |request|
        request.headers["Content-Type"] = "application/json"
        request.headers["X-Goog-Api-Key"] = key
        request.headers["X-Goog-FieldMask"] = "routes.duration"
        request.body = JSON.generate(body)
      end
    end
    # Protobuf JSON omits the repeated routes field when no route exists.
    return nil if data.empty? || (data["routes"] == [] && !data.key?("error"))
    unless data["routes"].is_a?(Array) && data["routes"].all? { |route| route.is_a?(Hash) && route["duration"].is_a?(String) && route["duration"].match?(/\A\d+(?:\.\d+)?s\z/) }
      raise SearchErrors::UpstreamError, "The transit provider returned an invalid response."
    end

    durations = data["routes"].map { |route| route["duration"].delete_suffix("s").to_f }
    if data.key?("error") || durations.any? { |duration| !duration.finite? }
      raise SearchErrors::UpstreamError, "The transit provider returned an invalid response."
    end
    durations.min
  end

  def self.waypoint(location)
    unless SearchHttp.coordinates?(location.latitude, location.longitude)
      raise SearchErrors::InvalidInput, "The route does not have valid coordinates."
    end
    { location: { latLng: { latitude: location.latitude, longitude: location.longitude } } }
  end
end
