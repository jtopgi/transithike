require "test_helper"

class TripPlansTest < ActiveSupport::TestCase
  # The first trip there, a last trip back at 8 PM, and a timetable there that answers as given, recording how it's asked.
  class FakeTransit
    attr_reader :timetables

    def initialize(there, departures)
      @there, @departures, @timetables = there, departures, []
    end

    def journey(origin:, destination:, time:) = @there

    def ways_back(origin:, destination:, like:, earliest:, deadline:, follow:)
      last = { departure: "2026-09-27T03:00:00Z", arrival: "2026-09-27T04:30:00Z", legs: [] }
      { back: last, last: last, same_way: true, trips: [last] }
    end

    def departures(origin:, destination:, time:, latest:, by_train:)
      @timetables << by_train
      @departures
    end
  end

  def trip(*modes)
    { departure: "2026-09-26T15:10:00Z", arrival: "2026-09-26T16:40:00Z", legs: modes.map { |mode| { mode: mode, name: mode } } }
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
    assert_equal [true], transit.timetables

    by_bus = trip("REGIONAL_RAIL", "BUS")
    transit = FakeTransit.new(by_bus, [])
    assert_equal [by_bus], plan(transit)[:departures]
    assert_equal [false], transit.timetables
  end
end
