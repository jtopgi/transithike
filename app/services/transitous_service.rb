require "time"

# Place search and public-transit routing from Transitous (https://transitous.org),
# a free, community-run MOTIS instance. Its usage policy requires an identifying
# User-Agent (see SearchHttp), attribution, open-source non-commercial use, and
# contacting the maintainers before sending heavier routing traffic.
module TransitousService
  GEOCODE_URL = "https://api.transitous.org/api/v1/geocode"
  PLAN_URL = "https://api.transitous.org/api/v6/plan"
  SOURCES_URL = "https://transitous.org/sources/"
  # Route starts are often farther than the default 15-minute walk from a stop.
  MAX_POST_TRANSIT_SECONDS = 30 * 60
  GEOCODE_CACHE_TTL = 1.day
  PLAN_CACHE_TTL = 15.minutes
  Location = Struct.new(:latitude, :longitude, :name, keyword_init: true)

  def self.geocode(origin, connection: nil, cache: Rails.cache)
    # Cache plain attributes rather than app classes, which reload in development.
    attributes = cache.fetch("transitous:geocode:v1:#{origin.downcase.squish}", expires_in: GEOCODE_CACHE_TTL) do
      connection ||= SearchHttp.connection(GEOCODE_URL)
      matches = SearchHttp.json(Array) do
        connection.get { |request| request.params = { text: origin, numResults: 1, language: "en" } }
      end
      location(matches.first).to_h unless matches.empty?
    end
    Location.new(**attributes) if attributes
  end

  def self.transit_duration(origin:, destination:, arrival_time:, connection: nil, cache: Rails.cache)
    params = {
      fromPlace: place(origin), toPlace: place(destination), time: arrival_time.utc.iso8601,
      arriveBy: true, timetableView: false, detailedLegs: false,
      maxPostTransitTime: MAX_POST_TRANSIT_SECONDS
    }
    cache_key = "transitous:plan:v1:#{params.values_at(:fromPlace, :toPlace, :time).join(':')}"
    cache.fetch(cache_key, expires_in: PLAN_CACHE_TTL) do
      connection ||= SearchHttp.connection(PLAN_URL, timeout: 10)
      data = SearchHttp.json { connection.get { |request| request.params = params } }
      journeys = data.values_at("itineraries", "direct")
      unless journeys.all? { |list| list.is_a?(Array) && list.all? { |journey| valid_journey?(journey) } }
        raise SearchErrors::UpstreamError, "The transit provider returned an invalid response."
      end

      # Direct walks count too: transit slower than the fastest walk is omitted.
      journeys.flatten(1).map { |journey| journey["duration"] }.min
    end
  end

  def self.location(match)
    unless match.is_a?(Hash) && SearchHttp.coordinates?(match["lat"], match["lon"])
      raise SearchErrors::UpstreamError, "The location provider returned invalid coordinates."
    end

    Location.new(latitude: match["lat"], longitude: match["lon"], name: label(match))
  end

  # For example "Pike Place Fish Market, Seattle, Washington, United States".
  def self.label(match)
    areas = Array(match["areas"]).select { |area| area.is_a?(Hash) && area["name"].is_a?(String) }
    names = [match["name"], areas.find { |area| area["default"] == true }&.fetch("name")] +
      [4, 2].map { |level| areas.find { |area| area["adminLevel"] == level }&.fetch("name") }
    names.grep(String).map(&:strip).reject(&:empty?).uniq.join(", ").presence
  end

  def self.place(location)
    unless SearchHttp.coordinates?(location.latitude, location.longitude)
      raise SearchErrors::InvalidInput, "The route does not have valid coordinates."
    end

    format("%.7f,%.7f", location.latitude, location.longitude)
  end

  def self.valid_journey?(journey)
    duration = journey.is_a?(Hash) ? journey["duration"] : nil
    duration.is_a?(Numeric) && duration.finite? && duration >= 0
  end
end
