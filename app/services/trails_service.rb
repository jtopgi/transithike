module TrailsService
  def self.get_trails(origin:, arrival_time:)
    trails = HikingProjectService.get_trails(
      lat: origin.latitude, lon: origin.longitude
    )

    trails.each do |trail|
      trailhead = [trail.latitude, trail.longitude].join(',')
      begin
        options = {arrival_time: arrival_time}
        trail.duration = Google::Maps.duration(origin, trailhead, options)
      rescue
        next
      end
    end

    trails.select! { |trail| trail.duration }
  end
end
