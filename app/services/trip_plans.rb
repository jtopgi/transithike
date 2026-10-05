# The trips there and back for a hike, from when trips set out: the trips there
# that arrive in time to hike all of it by sunset and before the last trip back,
# and the trips back after hiking all of it from the soonest arrival (from the
# far end, for hikes that finish there) that leave before dark, so no one waits
# for one in the dark.
module TripPlans
  # Hikes need at least this many trips there that arrive in time, and as many
  # back before dark, so missing one isn't a worry.
  MIN_TRIPS = 3

  # TripPlans.trips' for a trail, as it's hiked.
  def self.plan(trail, origin:, leave:, back_by:, transit: TransitousService)
    trips(**hike(trail), origin: origin, leave: leave, back_by: back_by, transit: transit)
  end

  # TripPlans.plan's when the trail has at least MIN_TRIPS trips there and as
  # many back, or nil. Without enough trips there, the trips back aren't looked up.
  def self.frequent(trail, origin:, leave:, back_by:, transit: TransitousService)
    plans = trips(**hike(trail), origin: origin, leave: leave, back_by: back_by, transit: transit, enough: true)
    plans if plans && frequent?(plans)
  end

  def self.frequent?(plans)
    plans[:departures].size >= MIN_TRIPS && Array(plans.dig(:ways, :trips)).size >= MIN_TRIPS
  end

  # { there:, ways:, departures:, sunset:, dusk: } for a hike from start
  # ([latitude, longitude]), back from finish when it's hiked there, that takes
  # hike minutes with the margin before the last trip back, with trips like
  # TransitousService's. departures are the trips there that arrive in time, in
  # order, and there is the one that arrives soonest, or #journey's when none
  # does. ways is TransitousService.ways_back's, with trips that leave by dusk.
  # sunset and dusk are Daylight's at start. With enough, nil when there are
  # fewer than MIN_TRIPS trips there.
  def self.trips(start:, finish:, hike:, origin:, leave:, back_by:, transit: TransitousService, enough: false)
    hike = hike.minutes
    walk = [hike - TrailsService::RETURN_MARGIN, 0.minutes].max
    start_place = Place.new(latitude: start[0], longitude: start[1])
    finish_place = Place.new(latitude: finish[0], longitude: finish[1]) if finish
    sunset, dusk = Daylight.sunset(leave, *start), Daylight.dusk(leave, *start)
    # Trips there that arrive in time to hike all of it by sunset and be back by the deadline.
    latest = [(sunset - walk if sunset), back_by - hike].compact.min
    departures = arriving(transit, origin, start_place, leave, latest)
    return if enough && departures.size < MIN_TRIPS

    # The soonest, and of those, the one that leaves latest.
    there = departures.min_by { |trip| [TransitousService.costed_arrival(trip), -Time.iso8601(trip[:departure]).to_i] } ||
      transit.journey(origin: origin, destination: start_place, time: leave)
    arrival = there ? Time.iso8601(there[:arrival]) : leave
    ways = transit.ways_back(origin: finish_place || start_place, destination: origin, like: there, earliest: arrival + hike,
      deadline: back_by, leave_by: dusk, follow: finish.nil?)
    last = Time.iso8601(ways[:last][:departure]) if ways[:last]
    # Only trips there that leave time to hike before the last trip back count.
    departures = departures.select { |trip| last && Time.iso8601(trip[:arrival]) + hike <= last }
    { there: there, ways: ways, departures: departures, sunset: sunset, dusk: dusk }
  end

  # Ways back like TransitousService.ways_back's with only the trips whose first
  # ride leaves by dusk, as for guides planned before trips back had to.
  def self.before_dark(ways, dusk)
    return ways unless dusk

    in_time = ->(trip) { trip && TransitousService.boarding(trip) <= dusk.utc.iso8601 }
    trips = Array(ways[:trips]).select(&in_time)
    ways.merge(back: (ways[:back] if in_time.(ways[:back])), last: (in_time.(ways[:last]) ? ways[:last] : trips.last), trips: trips)
  end

  # The trips there that arrive by latest, none when that's before leaving.
  def self.arriving(transit, origin, start, leave, latest)
    return [] unless latest > leave

    transit.departures(origin: origin, destination: start, time: leave, latest: latest, arrive_by: latest)
      .select { |trip| Time.iso8601(trip[:arrival]) <= latest }
  end

  # The trail's start, finish, and the minutes it takes to hike, the margin included.
  def self.hike(trail)
    { start: [trail.latitude, trail.longitude], finish: trail.finish, hike: (TrailsService.required_hours(trail) * 60).round }
  end
end
