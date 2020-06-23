Google::Maps.configure do |config|
  config.authentication_mode = Google::Maps::Configuration::API_KEY
  config.api_key = Rails.application.credentials.google_maps_key

  config.default_params = {
    directions_service: {
      mode: 'transit',
      transit_routing_preference: 'fewer_transfers'
    }
  }
end
