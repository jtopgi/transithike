class PhotosController < ApplicationController
  rate_limit to: 120, within: 1.minute, with: -> { head :too_many_requests }

  # Credited photos of the scenery near a route, if any.
  def index
    latitude, longitude = [params[:lat], params[:lon]].map { |value| Float(value, exception: false) if value.is_a?(String) }
    return head(:bad_request) unless SearchHttp.coordinates?(latitude, longitude)

    photos = WikipediaService.photos_near(latitude, longitude)
    expires_in 1.day, public: true
    photos ? render(json: photos) : head(:no_content)
  rescue SearchErrors::UpstreamError
    head :service_unavailable
  end
end
