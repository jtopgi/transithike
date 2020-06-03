require 'faraday'

module HikingProjectService
  URL = 'https://www.hikingproject.com/data/get-trails'

  def self.get_trails(coordinates)
    key = Rails.application.credentials.hiking_project_key
    lat = coordinates.first
    lon = coordinates.second
    json_response = Faraday.get(URL, {lat: lat, lon: lon, key: key})
    JSON.parse(json_response.body, object_class: OpenStruct).trails
  end
end
