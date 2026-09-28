class SearchesController < ApplicationController
  # The value of an <input type="datetime-local">, e.g. "2026-10-03T10:00".
  ARRIVAL_FORMAT = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::\d{2}(?:\.\d{1,3})?)?\z/

  def new
    @search = search_params
  end

  def show
    @search = search_params
    @trails = []
    origin = params[:origin]
    unless origin.is_a?(String) && origin.strip.present? && origin.length <= 200
      raise SearchErrors::InvalidInput, "Enter an origin of at most 200 characters."
    end
    maximum_length = params[:maximum_length]
    unless maximum_length.is_a?(String) && maximum_length.match?(/\A(?:[1-9]|[12]\d|30)\z/)
      raise SearchErrors::InvalidInput, "Choose a maximum length between 1 and 30 miles."
    end

    result = TrailsService.search(
      origin: origin.strip, arrival: arrival, maximum_length: maximum_length.to_i
    )
    @location, @arrival_time, @trails = result.location, result.arrival_time, result.trails
  rescue SearchErrors::InvalidInput => error
    @error = error.message
    render :show, status: :unprocessable_content
  rescue SearchErrors::UpstreamError => error
    @error = error.message
    render :show, status: :service_unavailable
  end

  private

  # Wall-clock parts; TrailsService reads them in the origin's time zone.
  def arrival
    value = params[:arrival_time]
    parts = value.is_a?(String) ? ARRIVAL_FORMAT.match(value)&.captures&.map(&:to_i) : nil
    unless parts && Date.valid_date?(*parts.first(3)) && parts[3].between?(0, 23) && parts[4].between?(0, 59)
      raise SearchErrors::InvalidInput, "Choose a valid arrival date and time."
    end

    parts
  end

  # Scalar values used to refill the search form.
  def search_params
    params.permit(:origin, :arrival_time, :maximum_length).to_h.symbolize_keys
  end
end
