require "test_helper"

class TripPlansTest < ActiveSupport::TestCase
  # Trips there and back that answer as given, noting how they're asked for.
  class FakeTransit
    attr_reader :asked

    def initialize(departures, back)
      @departures, @back, @asked = departures, back, {}
    end

    def departures(origin:, destination:, time:, latest:, arrive_by:, by_train: true)
      @asked[:departures] = [latest, arrive_by]
      @departures
    end

    def journey(origin:, destination:, time:)
      @asked[:journey] = time
      trip("15:10", "16:40")
    end

    def ways_back(origin:, destination:, like:, earliest:, deadline:, leave_by:, follow:)
      @asked[:ways_back] = [like, earliest, leave_by]
      { back: @back.first, last: @back.last, same_way: true, trips: @back }
    end

    def trip(leave, arrive)
      times = [leave, arrive].map { |time| "2026-09-#{time >= '12:00' ? 26 : 27}T#{time}:00Z" }
      { departure: times.first, arrival: times.last, legs: [] }
    end
  end

  SUNSET = Time.utc(2026, 9, 27, 1, 58)
  DUSK = Time.utc(2026, 9, 27, 2, 29)

  def trip(...) = FakeTransit.new([], []).trip(...)

  # A 3-mile loop, an hour and a half to hike, and half an hour more before the last trip back, from 8 AM PDT.
  def plan(transit, enough: false)
    trail = OverpassService::Trail.new(name: "Loop", latitude: 47.3, longitude: -122.0, length: 3.0, loop: true, plan: :loop)
    options = { origin: Place.new(latitude: 47.6, longitude: -122.3), leave: Time.utc(2026, 9, 26, 15),
      back_by: Time.utc(2026, 9, 27, 6), transit: transit }
    enough ? TripPlans.frequent(trail, **options) : TripPlans.plan(trail, **options)
  end

  test "the trips there arrive in time to hike by sunset and before the last trip back, which leaves before dark" do
    there = [trip("15:10", "16:40"), trip("16:10", "17:40"), trip("17:10", "18:40"), trip("20:00", "21:30")]
    back = [trip("21:00", "22:30"), trip("22:00", "23:30"), trip("23:00", "00:30")]
    transit = FakeTransit.new(there, back)
    plans = plan(transit)

    # The sun sets at 6:58 PM PDT, so the hike starts by 5:28 PM, and it's dark at 7:29 PM.
    assert_equal [SUNSET, DUSK], plans.values_at(:sunset, :dusk)
    assert_equal [SUNSET - 90.minutes] * 2, transit.asked[:departures]
    # The last trip back at 4 PM leaves time to hike after arriving by 2 PM, which the trip at 2:30 PM doesn't.
    assert_equal there.first(3), plans[:departures]
    assert_equal there.first, plans[:there]
    # Trips back are planned from the end of the hike after the soonest trip there, and leave before dark.
    assert_equal [there.first, Time.utc(2026, 9, 26, 18, 40), DUSK], transit.asked[:ways_back]
    assert TripPlans.frequent?(plans)
    assert_equal plans, plan(FakeTransit.new(there, back), enough: true)
  end

  test "of the trips there that arrive soonest, the one that leaves latest is the trip there" do
    there = [trip("15:10", "16:40"), trip("15:40", "16:40"), trip("16:10", "17:40")]
    assert_equal there.second, plan(FakeTransit.new(there, [trip("23:00", "00:30")]))[:there]
  end

  test "a hike needs three trips there and three back, and without enough trips there, the trips back aren't planned" do
    back = [trip("21:00", "22:30"), trip("22:00", "23:30"), trip("23:00", "00:30")]
    two = FakeTransit.new([trip("15:10", "16:40"), trip("16:10", "17:40")], back)
    assert_nil plan(two, enough: true)
    assert_nil two.asked[:ways_back]

    three = [trip("15:10", "16:40"), trip("16:10", "17:40"), trip("17:10", "18:40")]
    assert_nil plan(FakeTransit.new(three, back.first(2)), enough: true)
    refute TripPlans.frequent?(plan(FakeTransit.new(three, back.first(2))))
  end

  test "without a trip there in time, the trip there that arrives soonest is still shown" do
    transit = FakeTransit.new([], [trip("23:00", "00:30")])
    plans = plan(transit)
    assert_equal [[], trip("15:10", "16:40")], plans.values_at(:departures, :there)
    assert_equal Time.utc(2026, 9, 26, 15), transit.asked[:journey]
  end

  test "trips back that leave after dark are left out of guides planned before they had to leave before it" do
    trips = [trip("21:00", "22:30"), trip("23:00", "00:30"), trip("03:00", "04:30")]
    ways = { back: trips.first, last: trips.last, same_way: true, trips: trips }
    assert_equal({ back: trips.first, last: trips.second, same_way: true, trips: trips.first(2) }, TripPlans.before_dark(ways, DUSK))
    assert_equal ways, TripPlans.before_dark(ways, nil)
    assert_equal({ back: nil, last: nil, trips: [] }, TripPlans.before_dark({ back: trips.last, last: trips.last, trips: [trips.last] }, DUSK))
  end
end
