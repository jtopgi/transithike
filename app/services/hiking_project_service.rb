require 'faraday'
require 'faraday_override.rb'

module HikingProjectService
  URL = 'https://www.hikingproject.com/data/get-trails'
  MAX_DISTANCE = 50
  MAX_RESULTS = 500
  MIN_LENGTH = 1
  SORT = "distance"

  def self.get_trails(lat:, lon:, maximum_length:)
    key = Rails.application.credentials.hiking_project_key
    options = {lat: lat, lon: lon, maxDistance: MAX_DISTANCE, maxResults: MAX_RESULTS, minLength: MIN_LENGTH, sort: SORT, key: key}
    client = Faraday.new do |builder|
      builder.use :http_cache, store: Rails.cache, logger: Rails.logger
      builder.adapter Faraday.default_adapter
      builder.use Faraday::OverrideCacheControl, cache_control: 'public, max-age=3600'
    end
    json_response = client.get(URL, options)
    trails = JSON.parse(json_response.body, object_class: OpenStruct).trails
    trails.reject!{ |trail| trail.length > maximum_length.to_i }
  end
end
