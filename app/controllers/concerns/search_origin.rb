# The starting point a search asks for: typed text, with the coordinates of a
# chosen suggestion or the device's location when there are any, and the
# weekend day of the trip.
module SearchOrigin
  extend ActiveSupport::Concern

  # The origin text the page sends with the device's coordinates.
  CURRENT_LOCATION = "Current location"

  included do
    helper_method :coordinates, :requested_day, :requested_time_zone
  end

  private

  def origin_text
    origin = params[:origin] if params[:origin].is_a?(String)
    unless origin.present? && origin.strip.present? && origin.length <= 200
      raise SearchErrors::InvalidInput, "Enter a starting point of at most 200 characters."
    end

    origin.strip
  end

  # Suggestions and the device's location send coordinates, so no lookup is needed.
  def requested_origin(text)
    latitude, longitude = coordinates
    return text unless latitude

    Place.new(name: (text unless text == CURRENT_LOCATION), latitude: latitude, longitude: longitude)
  end

  def coordinates
    values = [params[:lat], params[:lon]].map { |value| Float(value, exception: false) if value.is_a?(String) }
    values if SearchHttp.coordinates?(*values)
  end

  # "saturday" or "sunday" when the search asks for one.
  def requested_day
    params[:day] if params[:day].is_a?(String) && TrailsService::WEEKEND_DAYS.key?(params[:day])
  end

  # The visitor's IANA time zone, which the page sends as a hint of where they are.
  def requested_time_zone
    zone = params[:tz]
    zone if zone.is_a?(String) && zone.length <= 64 && zone.match?(TransitousService::TIME_ZONE_FORMAT) &&
      ActiveSupport::TimeZone[zone]
  end
end
