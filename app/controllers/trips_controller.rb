# The trains, buses, and ferries to a route and back, and when they leave.
class TripsController < ApplicationController
  rate_limit to: 60, within: 1.minute, with: -> { head :too_many_requests }

  # from and to are "latitude,longitude"; leave is when the trip there starts,
  # and back_by is when the trip back must arrive.
  def show
    origin, route = [params[:from], params[:to]].map { |value| point(value) }
    leave, back_by = [params[:leave], params[:back_by]].map { |value| time(value) }
    unless origin && route && leave && back_by && leave.between?(1.day.ago, 8.days.from_now) &&
        back_by.between?(leave, leave + 1.day)
      return head(:bad_request)
    end

    there = TransitousService.journey(origin: origin, destination: route, time: leave)
    back = TransitousService.journey(origin: route, destination: origin, time: back_by, arrive_by: true)
    expires_in TransitousService::TRIP_CACHE_TTL
    render json: { there: there, back: back }
  rescue SearchErrors::UpstreamError
    head :service_unavailable
  end

  private

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
