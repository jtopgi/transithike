class PlacesController < ApplicationController
  rate_limit to: 60, within: 1.minute, with: -> { render json: [], status: :too_many_requests }, store: Rails.configuration.x.rate_limit_store

  # Starting-point suggestions as the visitor types; tz ranks nearby places first.
  def index
    query = params[:q].is_a?(String) ? params[:q].squish : ""
    return render(json: []) unless query.length.between?(3, 100)

    places = PhotonService.suggest(query, near: PhotonService.zone_center(params[:tz]))
    expires_in 1.hour, public: true
    render json: places.map { |place| { name: place.name, lat: place.latitude, lon: place.longitude } }
  rescue SearchErrors::UpstreamError
    render json: [], status: :service_unavailable
  end
end
