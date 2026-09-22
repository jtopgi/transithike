class SearchesController < ApplicationController
  def new; end

  def show
    @trails = []
    origin = params[:origin]
    unless origin.is_a?(String) && origin.strip.present? && origin.length <= 200
      raise SearchErrors::InvalidInput, "Enter an origin of at most 200 characters."
    end
    maximum_length = params[:maximum_length]
    unless maximum_length.is_a?(String) && maximum_length.match?(/\A(?:[1-9]|[12]\d|30)\z/)
      raise SearchErrors::InvalidInput, "Choose a maximum length between 1 and 30 miles."
    end

    @trails = TrailsService.get_trails(
      origin: origin.strip, arrival_time: arrival_time, maximum_length: maximum_length.to_i
    )
  rescue SearchErrors::InvalidInput => error
    @error = error.message
    render :show, status: :unprocessable_content
  rescue SearchErrors::UpstreamError => error
    @error = error.message
    render :show, status: :service_unavailable
  end

  private

  def arrival_time
    parts = (1..5).map do |index|
      value = params["arrival_time(#{index}i)"]
      unless value.is_a?(String) && value.match?(/\A\d{1,4}\z/)
        raise SearchErrors::InvalidInput, "Choose a valid arrival date and time."
      end
      value.to_i
    end
    year, month, day, hour, minute = parts
    unless Date.valid_date?(year, month, day) && hour.between?(0, 23) && minute.between?(0, 59)
      raise SearchErrors::InvalidInput, "Choose a valid arrival date and time."
    end
    time = Time.zone.local(*parts)
    unless time > Time.current && time <= 7.days.from_now
      raise SearchErrors::InvalidInput, "Choose an arrival time in the future, within the next 7 days."
    end
    time
  end
end
