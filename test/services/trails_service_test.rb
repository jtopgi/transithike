require "test_helper"

class TrailsServiceTest < ActiveSupport::TestCase
  class FakeTransit
    attr_reader :calls

    def initialize(durations, location: TransitousService::Location.new(latitude: 47, longitude: -122, name: "Seattle"))
      @durations, @location, @calls = durations, location, []
    end

    def geocode(origin)
      @location
    end

    def transit_duration(origin:, destination:, arrival_time:)
      @calls << destination
      @durations.fetch(destination.name)
    end
  end

  class FakeHiking
    attr_reader :arguments

    def initialize(trails)
      @trails = trails
    end

    def get_trails(**arguments)
      @arguments = arguments
      @trails
    end
  end

  def trail(name)
    OverpassService::Trail.new(name: name, latitude: 47.1, longitude: -122.1)
  end

  def search(transit:, hiking:)
    TrailsService.search(origin: "A & B / 東京", arrival_time: Time.current + 1.day, maximum_length: 3, transit: transit, hiking: hiking)
  end

  test "sorts transit durations when every route is reachable without destructive selection nil" do
    transit = FakeTransit.new({ "slow" => 900, "fast" => 100 })
    hiking = FakeHiking.new([trail("slow"), trail("fast")])
    result = search(transit: transit, hiking: hiking)
    assert_equal %w[fast slow], result.trails.map(&:name)
    assert_equal "Seattle", result.location.name
    assert_equal({ lat: 47, lon: -122, maximum_length: 3 }, hiking.arguments)
    assert_equal "A & B / 東京", result.trails.first.origin
  end

  test "filters unreachable routes and returns empty arrays consistently" do
    transit = FakeTransit.new({ "reachable" => 600, "unreachable" => nil })
    assert_equal ["reachable"], search(transit: transit, hiking: FakeHiking.new([trail("unreachable"), trail("reachable")])).trails.map(&:name)
    assert_empty search(transit: transit, hiking: FakeHiking.new([trail("unreachable")])).trails
    assert_empty search(transit: transit, hiking: FakeHiking.new([])).trails
  end

  test "missing geocode is actionable validation failure" do
    transit = FakeTransit.new({}, location: nil)
    hiking = FakeHiking.new([])
    assert_raises(SearchErrors::InvalidInput) { search(transit: transit, hiking: hiking) }
    assert_nil hiking.arguments
    assert_empty transit.calls
  end

  test "never performs more than ten transit calls" do
    trails = (1..30).map { |index| trail(index.to_s) }
    transit = FakeTransit.new(trails.to_h { |item| [item.name, 600] })
    assert_equal 10, search(transit: transit, hiking: FakeHiking.new(trails)).trails.length
    assert_equal 10, transit.calls.size
  end
end
