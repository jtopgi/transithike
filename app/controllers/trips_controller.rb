# The trains and other transit to a route and back the same way, when they
# leave, and where the route is.
class TripsController < ApplicationController
  rate_limit to: 60, within: 1.minute, with: -> { head :too_many_requests }, store: Rails.configuration.x.rate_limit_store

  # Trips show without where the route is when that takes longer.
  LOCATION_WAIT_SECONDS = 5

  # from and to are "latitude,longitude"; leave is when the trip there starts,
  # back_by is when the trip back must arrive, and hike is the minutes to hike
  # before heading back, the margin before the last trip back included. finish,
  # if given, is where a hike that doesn't come back ends, and the trips back
  # leave from. there is the soonest trip there that arrives in time to hike,
  # back is the first trip home after the hike and last is the last one that
  # leaves before dark, both the same way as the trip there where it runs in
  # time; frequent is whether there are at least TripPlans::MIN_TRIPS trips
  # there in time and as many back, and location is TrailsService.location's.
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
    # Planned as the search plans them, so its lookups are shared.
    plans = TripPlans.trips(start: [route.latitude, route.longitude], finish: finish && [finish.latitude, finish.longitude],
      hike: hike, origin: origin, leave: leave, back_by: back_by)
    ways = plans[:ways]
    location = TrailsService.settle([where], timeout: LOCATION_WAIT_SECONDS).first.value(0)
    expires_in TransitousService::TRIP_CACHE_TTL
    render json: { there: shown(plans[:there]), back: shown(ways[:back]), last: shown(ways[:last]), same_way: ways[:same_way],
      frequent: TripPlans.frequent?(plans), location: location }
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
