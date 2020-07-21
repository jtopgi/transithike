module TrailsService
  GOOGLE_MAPS_URL = [
    "https://www.google.com/maps/dir/?api=1",
    "origin=%{origin}",
    "destination=%{destination}",
    "travelmode=transit"
  ].join('&')

  def self.get_trails(origin:, arrival_time:, maximum_length:)
    trails = HikingProjectService.get_trails(
      lat: origin.latitude, lon: origin.longitude, maximum_length: maximum_length
    )

    trails.each do |trail|
      trailhead = [trail.latitude, trail.longitude].join(',')
      begin
        options = {arrival_time: arrival_time}
        trail.duration = Google::Maps.route(origin, trailhead, options).duration
        direction = {origin: origin, destination: trailhead}
        trail.google_maps_url = GOOGLE_MAPS_URL % direction
      rescue
        next
      end
    end

    trails
      .select! { |trail| trail.duration }
      .sort_by! { |trail| trail.duration.value }
  end
end
