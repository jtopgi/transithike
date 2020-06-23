module TrailsService
  def self.get_trails(location:, arrival_time:)
    location = Google::Maps.geocode(location).first
    trails =
      HikingProjectService.get_trails(lat: location.latitude, lon: location.longitude)

    trails.each do |trail|
      trailhead = [trail.latitude, trail.longitude].join(',')
      begin
        trail.duration = Google::Maps.duration(location, trailhead, {arrival_time: arrival_time})
      rescue
        next
      end
    end

    trails.select! { |trail| trail.duration }
  end
end
