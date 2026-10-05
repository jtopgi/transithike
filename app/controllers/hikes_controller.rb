# A hike found by a search, in detail: the route, its photos, and the
# timetables of the trips there that leave time to hike it and of the trips back.
class HikesController < ApplicationController
  rate_limit to: 30, within: 1.minute, with: -> { head :too_many_requests }, store: Rails.configuration.x.rate_limit_store

  PLANS = %w[loop out_and_back through].freeze
  # The page shows without the route's highlights, terrain, or photos when they take longer.
  EXTRAS_WAIT_SECONDS = 10

  # route is the OpenStreetMap relation id; from, to, and finish are
  # "latitude,longitude" for the search's starting point, where transit
  # reaches the route, and where a hike to the far end finishes; station, if
  # given, is "latitude,longitude" for the station trips leave from, and
  # station_name its name, and otherwise they leave from the starting point;
  # plan is how it's hiked; leave and back_by are when trips there start and
  # trips back must arrive; tz is the starting point's time zone, and origin
  # its name.
  def show
    origin, start = [params[:from], params[:to]].map { |value| point(value) }
    finish = point(params[:finish]) if params[:plan] == "through"
    station = point(params[:station]) if params.key?(:station)
    leave, back_by = [params[:leave], params[:back_by]].map { |value| time(value) }
    @zone = ActiveSupport::TimeZone[params[:tz]] if params[:tz].is_a?(String) && params[:tz].length <= 64
    route = Integer(params[:route], 10, exception: false) if params[:route].is_a?(String)
    @origin_name, @station_name = [params[:origin], params[:station_name]].map { |name| name_param(name) }
    unless origin && start && route&.positive? && PLANS.include?(params[:plan]) && (finish || params[:plan] != "through") &&
        (station || !params.key?(:station)) &&
        leave && back_by && @zone && leave.between?(1.day.ago, 8.days.from_now) && back_by.between?(leave, leave + 1.day)
      return head(:bad_request)
    end

    # Trips leave from the station, and the page links back to the search from the starting point.
    from = station || origin
    @trail = OverpassService.trails_for([route], lat: from.latitude, lon: from.longitude).first
    return head(:not_found) unless @trail

    @trail.latitude, @trail.longitude, @trail.plan, @trail.finish = start.latitude, start.longitude, params[:plan].to_sym, finish&.then { |place| [place.latitude, place.longitude] }
    @trail.origin = @origin_name
    if station
      @trail.station = Station.new(name: @station_name || "the station", latitude: station.latitude, longitude: station.longitude)
    end
    # The route's highlights, terrain, and photos, and where it is, are looked up while transit is planned,
    # where it is on its own, so a slow lookup of it doesn't hold up the rest.
    trail = @trail
    extras = TrailsService.start do
      [optional { OverpassService.highlights([trail])[trail.osm_id] }, optional { ElevationService.terrain([trail])[trail.osm_id] },
        optional { WikipediaService.photos_near(trail.photo_points) }]
    end
    # The traffic noise along it, where the noise map covers where it is, on its own too.
    noise = TrailsService.start do
      NoiseService.noise([trail])[trail.osm_id] if NoiseService.covers_place?(trail.latitude, trail.longitude)
    end
    where = TrailsService.start { TrailsService.location(trail, origin) }
    @from, @leave, @back_by = from, leave.in_time_zone(@zone), back_by.in_time_zone(@zone)
    @from_name = station ? @station_name || "the station" : @origin_name
    @results_path = search_path({ origin: @origin_name || SearchOrigin::CURRENT_LOCATION, lat: origin.latitude,
      lon: origin.longitude, day: @leave.saturday? ? "saturday" : "sunday", tz: @zone.tzinfo.name })
    trips = TripPlans.plan(@trail, origin: from, leave: leave, back_by: back_by)
    @there, @ways, @departures, @trail.sunset = trips.values_at(:there, :ways, :departures, :sunset)
    TrailsService.settle([extras, where, noise], timeout: EXTRAS_WAIT_SECONDS)
    highlights, @trail.terrain, @photos = extras.value(0) || []
    @trail.noise = noise.value(0)
    @trail.highlights = highlights || []
    @trail.location = where.value(0)
    expires_in TransitousService::TRIP_CACHE_TTL
  rescue SearchErrors::UpstreamError
    # The lookups started alongside finish rather than outlive the request.
    TrailsService.settle([extras, where, noise].compact, timeout: EXTRAS_WAIT_SECONDS) if extras
    @unavailable = true
    render :show, status: :service_unavailable
  end

  private

  def optional
    yield
  rescue SearchErrors::UpstreamError
    nil
  end

  def name_param(value)
    value.strip.truncate(100) if value.is_a?(String) && value.strip.present?
  end

  def point(value)
    latitude, longitude = value.split(",", 2).map { |part| Float(part, exception: false) } if value.is_a?(String)
    Place.new(latitude: latitude, longitude: longitude) if SearchHttp.coordinates?(latitude, longitude)
  end

  def time(value)
    Time.iso8601(value) if value.is_a?(String)
  rescue ArgumentError
    nil
  end
end
