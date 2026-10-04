# The trips there and back for a hike: the first trip there, the trips back
# after hiking all of it from that arrival (from the far end, for hikes that
# finish there) until the first after sunset, and the trips there that leave
# time to hike all of it by sunset and before the last trip back.
module TripPlans
  # { there:, ways:, departures:, sunset: }, with the trips like
  # TransitousService's: ways is TransitousService.ways_back's, with its trips
  # only until the first that leaves at sunset or later, which is after_sunset;
  # departures are in order, and sunset is Daylight.sunset's at the route that day.
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
    { there: there, ways: until_sunset(ways, sunset), departures: departures.presence || [there].compact.select(&in_time),
      sunset: sunset }
  end

  # The ways back with their trips only until the first that leaves at sunset
  # or later, as after_sunset, where sunset is the hike's deadline: the hike is
  # done by then, so later trips are only for staying after dark.
  def self.until_sunset(ways, sunset)
    last = Time.iso8601(ways[:last][:departure]) if ways[:last]
    trips = Array(ways[:trips])
    dusk = after_sunset(trips, sunset) if sunset_first?(sunset, last)
    ways.merge(trips: dusk ? trips[..trips.index(dusk)] : trips, after_sunset: dusk)
  end

  # The first trip back that leaves at sunset or later, which someone hiking
  # until sunset takes, or nil without a sunset or one.
  def self.after_sunset(trips, sunset)
    sunset && trips.find { |trip| Time.iso8601(trip[:departure]) >= sunset }
  end

  # Whether sunset is the hike's deadline rather than the last trip back,
  # which has to leave RETURN_MARGIN after the hike: so the last trip back
  # leaves later than that after sunset, or isn't known.
  def self.sunset_first?(sunset, last_return)
    !sunset.nil? && (last_return.nil? || sunset <= last_return - TrailsService::RETURN_MARGIN)
  end
end
