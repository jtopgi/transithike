class PhotosController < ApplicationController
  rate_limit to: 120, within: 1.minute, with: -> { head :too_many_requests }, store: Rails.configuration.x.rate_limit_store
  # Photos are looked for around at most this many points along a route.
  MAX_POINTS = 3

  # Credited photos of nature along a route, if any.
  def index
    points = requested_points
    return head(:bad_request) unless points

    photos = WikipediaService.photos_near(points)
    expires_in 1.day, public: true
    photos ? render(json: photos) : head(:no_content)
  rescue SearchErrors::UpstreamError
    head :service_unavailable
  end

  private

  # [latitude, longitude] pairs from points as "latitude,longitude|...", the
  # route's middle first, or from lat and lon, or nil when any is invalid.
  def requested_points
    text = params[:points].is_a?(String) ? params[:points] : [params[:lat], params[:lon]].then { |pair| pair.join(",") if pair.all?(String) }
    points = text.to_s.split("|").first(MAX_POINTS).map do |point|
      point.split(",").map { |value| Float(value, exception: false) }
    end
    points if points.any? && points.all? { |point| point.size == 2 && SearchHttp.coordinates?(*point) }
  end
end
