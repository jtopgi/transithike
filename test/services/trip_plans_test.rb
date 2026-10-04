require "test_helper"

class TripPlansTest < ActiveSupport::TestCase
  # The first trip there, a last trip back at 8 PM, and a timetable there that answers as given, recording how it's asked.
  class FakeTransit
    attr_reader :timetables, :latest

    def initialize(there, departures)
      @there, @departures, @timetables, @latest = there, departures, [], []
    end

    def journey(origin:, destination:, time:) = @there

    def ways_back(origin:, destination:, like:, earliest:, deadline:, follow:)
      last = { departure: "2026-09-27T03:00:00Z", arrival: "2026-09-27T04:30:00Z", legs: [] }
      { back: last, last: last, same_way: true, trips: [last] }
    end

    def departures(origin:, destination:, time:, latest:, arrive_by:, by_train:)
      @timetables << [by_train, arrive_by == latest]
      @latest << latest
      @departures
    end
  end

  def trip(*modes, arrival: "2026-09-26T16:40:00Z")
    { departure: "2026-09-26T15:10:00Z", arrival: arrival, legs: modes.map { |mode| { mode: mode, name: mode } } }
  end

  def plan(transit)
    trail = OverpassService::Trail.new(name: "Loop", latitude: 47.3, longitude: -122.0, length: 3.0, loop: true, plan: :loop)
    TripPlans.plan(trail, origin: Place.new(latitude: 47.6, longitude: -122.3), leave: Time.utc(2026, 9, 26, 15),
      back_by: Time.utc(2026, 9, 27, 6), transit: transit)
  end

  test "the timetable there goes by train only when the first trip there does, and lists that trip when it has none in time" do
    by_train = trip("SUBWAY", "REGIONAL_RAIL")
    transit = FakeTransit.new(by_train, [by_train])
    assert_equal [by_train], plan(transit)[:departures]
    # Rides at the end are only walked where trips still arrive in time to hike.
    assert_equal [[true, true]], transit.timetables

    by_bus = trip("REGIONAL_RAIL", "BUS")
    transit = FakeTransit.new(by_bus, [])
    assert_equal [by_bus], plan(transit)[:departures]
    assert_equal [[false, true]], transit.timetables

    # A first trip there too late to hike before the last trip back isn't listed either.
    too_late = trip("REGIONAL_RAIL", arrival: "2026-09-27T02:00:00Z")
    assert_empty plan(FakeTransit.new(too_late, []))[:departures]
  end

  def back(departure)
    { departure: departure, arrival: (Time.iso8601(departure) + 90.minutes).utc.iso8601, legs: [] }
  end

  test "trips back are only listed until the first after sunset, where sunset is the hike's deadline" do
    sunset = Time.utc(2026, 9, 27, 1, 58)
    trips = %w[2026-09-26T21:00:00Z 2026-09-27T01:30:00Z 2026-09-27T02:10:00Z 2026-09-27T03:00:00Z].map { |time| back(time) }
    ways = { back: trips.first, last: trips.last, same_way: true, trips: trips }
    assert_equal [trips.first(3), trips[2]], TripPlans.until_sunset(ways, sunset).values_at(:trips, :after_sunset)
    # When the last trip back leaves less than half an hour after sunset, it's the deadline, and every trip is listed.
    early = { back: trips.first, last: trips[2], same_way: true, trips: trips.first(3) }
    assert_equal [trips.first(3), nil], TripPlans.until_sunset(early, sunset).values_at(:trips, :after_sunset)
    # Without a sunset, or trips, every trip is listed.
    assert_equal [trips, nil], TripPlans.until_sunset(ways, nil).values_at(:trips, :after_sunset)
    assert_equal({ trips: [], after_sunset: nil }, TripPlans.until_sunset({}, sunset))
  end

  test "sunset is the hike's deadline unless the last trip back leaves before it, or less than half an hour after" do
    sunset = Time.utc(2026, 9, 27, 1, 58)
    assert TripPlans.sunset_first?(sunset, sunset + 30.minutes)
    assert TripPlans.sunset_first?(sunset, nil)
    assert_not TripPlans.sunset_first?(sunset, sunset + 29.minutes)
    assert_not TripPlans.sunset_first?(nil, sunset)
  end

  test "trips there have to arrive in time to hike by sunset, before the last trip back" do
    # The sun sets at 6:58 PM PDT, before the last trip back at 8 PM, so the hour and a half's hike starts by 5:28 PM.
    in_time, dusk = trip("REGIONAL_RAIL", arrival: "2026-09-27T00:20:00Z"), trip("REGIONAL_RAIL", arrival: "2026-09-27T00:40:00Z")
    transit = FakeTransit.new(in_time, [in_time, dusk])
    plans = plan(transit)
    assert_equal [in_time], plans[:departures]
    assert_equal Time.utc(2026, 9, 27, 1, 58), plans[:sunset]
    # The only trip back, at 8 PM, is the first after sunset.
    assert_equal "2026-09-27T03:00:00Z", plans[:ways][:after_sunset][:departure]
    # The timetable only looks for trips that arrive by then.
    assert_equal [Time.utc(2026, 9, 27, 0, 28)], transit.latest
  end
end
