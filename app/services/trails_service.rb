module TrailsService
  Result = Struct.new(:location, :trails, keyword_init: true)

  def self.search(origin:, arrival_time:, maximum_length:, transit: TransitousService, hiking: OverpassService)
    location = transit.geocode(origin)
    raise SearchErrors::InvalidInput, "We could not find that origin. Please enter a more specific location." unless location

    trails = hiking.get_trails(lat: location.latitude, lon: location.longitude, maximum_length: maximum_length)
      .first(OverpassService::MAX_TRANSIT_ROUTES).filter_map do |trail|
        duration = transit.transit_duration(origin: location, destination: trail, arrival_time: arrival_time)
        next if duration.nil?

        trail.duration = duration
        trail.origin = origin
        trail
      end.sort_by(&:duration)
    Result.new(location: location, trails: trails)
  end
end
