class SearchesController < ApplicationController
  # The origin text the page sends with the device's coordinates.
  CURRENT_LOCATION = "Current location"

  rate_limit to: 20, within: 1.minute, only: :show, with: :too_many_searches

  def new
    @origin = params[:origin] if params[:origin].is_a?(String)
  end

  def show
    @trails = []
    @origin = params[:origin] if params[:origin].is_a?(String)
    unless @origin.present? && @origin.strip.present? && @origin.length <= 200
      raise SearchErrors::InvalidInput, "Enter a starting point of at most 200 characters."
    end

    @result = TrailsService.search(origin: requested_origin(@origin.strip))
    @trails = @result.trails
  rescue SearchErrors::InvalidInput => error
    @error = error.message
    render :show, status: :unprocessable_content
  rescue SearchErrors::UpstreamError => error
    @error = error.message
    render :show, status: :service_unavailable
  end

  private

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
  helper_method :coordinates

  def too_many_searches
    @trails = []
    @error = "Too many searches in a short time. Please wait a minute and try again."
    render :show, status: :too_many_requests
  end
end
