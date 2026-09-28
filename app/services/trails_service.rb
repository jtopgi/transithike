module TrailsService
  def self.get_trails(origin:, arrival_time:, maximum_length:, maps: GoogleMapsService, hiking: OverpassService)
    location = maps.geocode(origin)
    raise SearchErrors::InvalidInput, "We could not find that origin. Please enter a more specific location." unless location

    hiking.get_trails(lat: location.latitude, lon: location.longitude, maximum_length: maximum_length)
      .first(OverpassService::MAX_TRANSIT_ROUTES).filter_map do |trail|
        duration = maps.transit_duration(origin: location, destination: trail, arrival_time: arrival_time)
        next if duration.nil?

        trail.duration = duration
        trail.origin = origin
        trail
      end.sort_by(&:duration)
  end
end
