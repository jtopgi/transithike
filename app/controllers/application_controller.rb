class ApplicationController < ActionController::Base
  before_action :set_timezone

  private

  def set_timezone
    time_zone = request_location.data["timezone"]
    Time.zone = time_zone
  end

  def request_location
    if Rails.env.test? || Rails.env.development?
      Geocoder.search("73.36.246.56").first
    else
      request.location
    end
  end
end
