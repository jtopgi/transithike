require 'faraday'

module HikingProjectService
  URL = 'https://www.hikingproject.com/data/get-trails'
  MAX_DISTANCE = 50
  MAX_RESULTS = 500
  MIN_LENGTH = 1
  SORT = "distance"

  def self.get_trails(lat:, lon:)
    key = Rails.application.credentials.hiking_project_key
    options = {lat: lat, lon: lon, maxDistance: MAX_DISTANCE, maxResults: MAX_RESULTS, minLength: MIN_LENGTH, sort: SORT, key: key,}
    json_response = Faraday.get(URL, options)
    JSON.parse(json_response.body, object_class: OpenStruct).trails
  end
end
