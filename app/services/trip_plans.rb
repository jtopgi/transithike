# The trips there and back for a hike: the first trip there, the trips back
# after hiking all of it from that arrival (from the far end, for hikes that
# finish there), and the trips there that leave time to hike all of it by
# sunset and before the last trip back.
module TripPlans
  # { there:, ways:, departures:, sunset: }, with the trips like
  # TransitousService's: ways is TransitousService.ways_back's, departures are
  # in order, and sunset is Daylight.sunset's at the route that day.
  def self.plan(trail, origin:, leave:, back_by:, transit: TransitousService)
    start = Place.new(latitude: trail.latitude, longitude: trail.longitude)
    finish = Place.new(latitude: trail.finish[0], longitude: trail.finish[1]) if trail.finish
    # In whole minutes, as the results page looks trips up, so its lookups are shared.
    hike = (TrailsService.required_hours(trail) * 60).round.minutes
    walk = (TrailsService.hike_hours(trail) * 60).round.minutes
    sunset = Daylight.sunset(leave, trail.latitude, trail.longitude)
    there = transit.journey(origin: origin, destination: start, time: leave)
    arrival = there ? Time.iso8601(there[:arrival]) : leave
    ways = transit.ways_back(origin: finish || start, destination: origin, like: there, earliest: arrival + hike,
      deadline: back_by, follow: finish.nil?)
    last = Time.iso8601(ways[:last][:departure]) if ways[:last]
    # Trips there that arrive in time to hike by sunset and before the last trip back.
    latest = [(last - hike if last), (sunset - walk if sunset)].compact.min
    in_time = ->(trip) { latest.nil? || Time.iso8601(trip[:arrival]) <= latest }
    departures = if last && there
      # No trip there that leaves later than this arrives in time. The timetable
      # goes by train only when the first trip there does, so it lists that trip.
      transit.departures(origin: origin, destination: start, time: leave, latest: latest, arrive_by: latest,
        by_train: TransitousService.by_train?(there)).select(&in_time)
    end
    { there: there, ways: ways, departures: departures.presence || [there].compact.select(&in_time), sunset: sunset }
  end
end
