require "test_helper"
require_relative "../support/guide_fixtures"

class GuideServiceTest < ActiveSupport::TestCase
  include GuideFixtures

  teardown { GuideService.directory = nil }

  # A search that finds the trails, as TrailsService's does.
  class FakeSearch
    attr_reader :origins

    def initialize(trails)
      @trails, @origins = trails, []
    end

    def search(origin:, day:)
      @origins << [origin, day]
      departure = ActiveSupport::TimeZone["America/New_York"].parse("2026-10-10 08:00")
      TrailsService::Result.new(place: origin, departure_time: departure, return_by: departure.change(hour: 23),
        trails: @trails, returns_checked: true, complete: true)
    end
  end

  # Trips there by train, and trips back after the hike, for TripPlans.
  class FakeTransit
    def journey(origin:, destination:, time:)
      { departure: (time + 10.minutes).utc.iso8601, arrival: (time + 90.minutes).utc.iso8601,
        legs: [{ mode: "SUBURBAN", name: "Hudson Line", to_name: "Cold Spring" }, { mode: "BUS", name: "5", to_name: "Main St" }] }
    end

    def ways_back(origin:, destination:, like:, earliest:, deadline:, follow:)
      trip = { departure: earliest.utc.iso8601, arrival: (earliest + 90.minutes).utc.iso8601, legs: [] }
      last = { departure: (deadline - 2.hours).utc.iso8601, arrival: (deadline - 30.minutes).utc.iso8601, legs: [] }
      { back: trip, last: last, same_way: follow ? true : nil, trips: [trip, last] }
    end

    def departures(origin:, destination:, time:, latest:, arrive_by: nil, by_train: true)
      [journey(origin: origin, destination: destination, time: time)]
    end
  end

  # Every route is in Cold Spring, and Midtown Manhattan in New York.
  class FakePlaces
    def locality(latitude, longitude)
      { locality: latitude > 41 ? "Cold Spring" : "New York", region: "New York", country: "United States" }
    end
  end

  class FakePhotos
    def photos_near(points)
      { title: "Hudson Highlands State Park (New York)", article_url: nil,
        photos: [{ image_url: "https://upload.wikimedia.org/a.jpg", file_url: "https://commons.wikimedia.org/a", credit: "Ann",
          caption: "Ridge" }] }
    end
  end

  def trail(name, osm_id, scenic: 0, **attributes)
    OverpassService::Trail.new(name: name, osm_id: osm_id, summary: "A route.", latitude: 41.4, longitude: -73.9, length: 3,
      path: [[[41.4, -73.9], [41.42, -73.9]]], loop: true, paved: 0, notable: false, duration: 5_400, transfers: 0,
      arrival: Time.utc(2026, 10, 10, 13, 30), last_return: Time.utc(2026, 10, 11, 0), score: 1, plan: :loop,
      terrain: { climb: scenic * 100, relief: scenic * 100 }, highlights: [], **attributes)
  end

  def guide
    GuideService.guides.find { |candidate| candidate.slug == "new-york-city" }
  end

  test "a photo lookup that fails is tried once more" do
    flaky = Class.new(FakePhotos) do
      attr_reader :calls

      def photos_near(points)
        @calls = @calls.to_i + 1
        raise SearchErrors::UpstreamError, "slow" if @calls == 1

        super
      end
    end.new
    data = stub_const(GuideService, :PHOTO_RETRY_SECONDS, 0) do
      GuideService.build(guide, search: FakeSearch.new([trail("Ridge Loop", 1)]), transit: FakeTransit.new, photos: flaky,
        places: FakePlaces.new)
    end
    assert_equal [1, 2], [data[:hikes].sole[:photos].size, flaky.calls]
  end

  test "a guide plans each hike's trips and photos, most scenic first, and tells plain or shared names apart by place" do
    trails = [trail("White Trail", 1, scenic: 1), trail("Breakneck Ridge Trail", 2, scenic: 4), trail("White Trail", 3),
      trail("Ridge Loop", 4, scenic: 2, plan: :through, loop: false, finish: [41.42, -73.9])]
    search = FakeSearch.new(trails)
    data = GuideService.build(guide, search: search, transit: FakeTransit.new, photos: FakePhotos.new, places: FakePlaces.new)

    assert_equal [["Midtown Manhattan", 40.7536, -73.9832, "America/New_York"], "saturday"],
      search.origins.sole.then { |place, day| [place.to_a, day] }
    assert_equal ["Breakneck Ridge Trail", "Ridge Loop", "White Trail (Hudson Highlands State Park)",
      "White Trail (Hudson Highlands State Park)"], data[:hikes].pluck(:title)
    assert_equal ["breakneck-ridge-trail", "ridge-loop", "white-trail-hudson-highlands-state-park",
      "white-trail-hudson-highlands-state-park-2"], data[:hikes].pluck(:slug)
    hike = data[:hikes].first
    # Each hike says where it is, without the country it shares with the city.
    assert_equal ["Cold Spring, New York"], data[:hikes].map { |each| each.dig(:trail, :location) }.uniq
    assert_equal ["Hudson Highlands State Park", "Hudson Line", true, 2, 1, 1],
      [hike[:area], hike.dig(:there, :legs, 0, :name), hike.dig(:ways, :same_way), hike.dig(:ways, :trips).size,
        hike[:departures].size, hike[:photos].size]
    # A hike to its far end comes back from there any way.
    assert_nil data[:hikes].second.dig(:ways, :same_way)
    assert_equal ["2026-10-10T08:00:00-04:00", "2026-10-10T23:00:00-04:00"], data.values_at(:departure_time, :return_by)
    assert_equal({ climb: 400, relief: 400 }, hike.dig(:trail, :terrain))
    assert_equal "2026-10-10T13:30:00Z", hike.dig(:trail, :arrival)
  end

  test "slugs are lowercase letters and digits joined by hyphens, as the guides' addresses accept" do
    previous = { hikes: [{ slug: "old_slug__2", trail: { osm_id: 2 } }] }
    data = GuideService.build(guide, previous: previous, search: FakeSearch.new([trail("koasa_trail-etappe_3", 1),
      trail("Somewhere else", 2), trail("Pilgrims' Way & Co.", 3)]), transit: FakeTransit.new, photos: FakePhotos.new, places: FakePlaces.new)
    assert_equal ["koasa-trail-etappe-3", "old-slug-2", "pilgrims-way-co"], data[:hikes].pluck(:slug)
    assert data[:hikes].all? { |hike| hike[:slug].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) }
  end

  test "hikes keep the slugs they had, and without a place, plain names stay as they are" do
    previous = { hikes: [{ slug: "old-white-trail", trail: { osm_id: 1 } }] }
    photos = Class.new { def photos_near(_) = nil }.new
    data = GuideService.build(guide, previous: previous, search: FakeSearch.new([trail("White Trail", 1), trail("Loop 2", 2)]),
      transit: FakeTransit.new, photos: photos, places: FakePlaces.new)
    # Without a park nearby, the station the train goes to tells them apart.
    assert_equal [["old-white-trail", "White Trail (Cold Spring)"], ["loop-2-cold-spring", "Loop 2 (Cold Spring)"]],
      data[:hikes].map { |hike| hike.values_at(:slug, :title) }
  end

  test "a new guide replaces the last only with enough hikes, and pages read the guide written" do
    GuideService.directory = Pathname(Dir.mktmpdir("guides"))
    hikes = ->(count) { guide_data.merge(hikes: Array.new(count) { |index| guide_data[:hikes].first.merge(slug: "hike-#{index}") }) }
    refute GuideService.write(guide, hikes.(GuideService::MIN_HIKES - 1))
    assert_nil GuideService.page("new-york-city")
    assert GuideService.write(guide, hikes.(30))
    assert_equal 30, GuideService.page("new-york-city").hikes.size
    # Fewer than six in ten of the last guide's hikes look like a provider's bad day.
    refute GuideService.write(guide, hikes.(17))
    assert_equal 30, GuideService.previous(guide)[:hikes].size
    assert GuideService.write(guide, hikes.(18))
    assert_equal 18, GuideService.page("new-york-city").hikes.size
  end

  test "a guide's page has its hikes' routes, trips, and photos, in the city's time zone" do
    write_guide
    page = GuideService.page("new-york-city")

    assert_equal ["New York City", "Midtown Manhattan"], [page.guide.name, page.guide.origin]
    assert_equal "Saturday, October 10, 8:00 AM EDT", page.departure_time.strftime("%A, %B %-d, %-l:%M %p %Z")
    hike = page.hike("breakneck-ridge-trail")
    assert_equal [:out_and_back, 2.5, 5, Time.utc(2026, 10, 11, 0, 50)],
      [hike.trail.plan, hike.trail.length, TrailsService.hike_miles(hike.trail), hike.trail.last_return]
    assert_equal "Midtown Manhattan", hike.trail.origin
    assert_equal [{ kind: "viewpoint", name: "Breakneck Ridge" }, { kind: "peak", name: "Sugarloaf Mountain" }], hike.trail.highlights
    assert_equal ["Hudson Line", 2], [hike.there[:legs].sole[:name], hike.ways[:trips].size]
    assert_nil page.hike("missing")
    assert_same page, GuideService.page("new-york-city")
    assert_nil GuideService.page("atlantis")
    assert_nil GuideService.page("london")
  end
end
