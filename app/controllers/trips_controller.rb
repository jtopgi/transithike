# The trains and other transit to a route and back the same way, when they
# leave, and where the route is.
class TripsController < ApplicationController
  rate_limit to: 60, within: 1.minute, with: -> { head :too_many_requests }, store: Rails.configuration.x.rate_limit_store

  # Trips show without where the route is when that takes longer.
  LOCATION_WAIT_SECONDS = 5

  # from and to are "latitude,longitude"; leave is when the trip there starts,
  # back_by is when the trip back must arrive, and hike is the minutes to hike
  # before heading back. finish, if given, is where a hike that doesn't come
  # back ends, and the trips back leave from. back is the first trip home after
  # the hike and last is the last one, both the same way as the trip there
  # where it runs in time, and after_sunset is the first that leaves at sunset
  # or later, for hiking until sunset, where that's the hike's deadline;
  # location is TrailsService.location's.
  def show
    origin, route = [params[:from], params[:to]].map { |value| point(value) }
    finish = point(params[:finish]) if params.key?(:finish)
    leave, back_by = [params[:leave], params[:back_by]].map { |value| time(value) }
    hike = params.key?(:hike) ? minutes(params[:hike]) : 0
    unless origin && route && leave && back_by && (finish || !params.key?(:finish)) &&
        leave.between?(1.day.ago, 8.days.from_now) && back_by.between?(leave, leave + 1.day) &&
        hike&.between?(0, (back_by - leave) / 60)
      return head(:bad_request)
    end

    where = TrailsService.start { TrailsService.location(route, origin) }
    there = TransitousService.journey(origin: origin, destination: route, time: leave)
    arrival = there ? Time.iso8601(there[:arrival]) : leave
    ways = TransitousService.ways_back(origin: finish || route, destination: origin, like: there,
      earliest: arrival + hike.minutes, deadline: back_by, follow: finish.nil?)
    location = TrailsService.settle([where], timeout: LOCATION_WAIT_SECONDS).first.value(0)
    dusk = TripPlans.until_sunset(ways, Daylight.sunset(leave, route.latitude, route.longitude))[:after_sunset]
    expires_in TransitousService::TRIP_CACHE_TTL
    render json: { there: shown(there), back: shown(ways[:back]), last: shown(ways[:last]), after_sunset: shown(dusk),
      same_way: ways[:same_way], location: location }
  rescue SearchErrors::UpstreamError
    # The lookup started alongside finishes rather than outlive the request.
    TrailsService.settle([where], timeout: LOCATION_WAIT_SECONDS) if where
    head :service_unavailable
  end

  private

  # What the page shows of a trip: when it leaves and arrives, and its rides.
  def shown(trip)
    trip&.merge(legs: trip[:legs].map { |leg| leg.slice(:mode, :name, :agency, :headsign) })
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

  def minutes(value)
    Integer(value, 10, exception: false) if value.is_a?(String)
  end
end
