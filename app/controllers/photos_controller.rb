class PhotosController < ApplicationController
  rate_limit to: 120, within: 1.minute, with: -> { head :too_many_requests }

  # A credited photo of a park or natural area near a route start, if any.
  def show
    latitude, longitude = [params[:lat], params[:lon]].map { |value| Float(value, exception: false) if value.is_a?(String) }
    return head(:bad_request) unless SearchHttp.coordinates?(latitude, longitude)

    photo = WikipediaService.photo_near(latitude, longitude)
    expires_in 1.day, public: true
    photo ? render(json: photo) : head(:no_content)
  rescue SearchErrors::UpstreamError
    head :service_unavailable
  end
end
