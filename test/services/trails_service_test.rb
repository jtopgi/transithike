require "test_helper"

class TrailsServiceTest < ActiveSupport::TestCase
  class FakeMaps
    attr_reader :calls

    def initialize(durations, location: GoogleMapsService::Location.new(latitude: 47, longitude: -122))
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

  def search(maps:, hiking:)
    TrailsService.get_trails(origin: "A & B / 東京", arrival_time: Time.current + 1.day, maximum_length: 3, maps: maps, hiking: hiking)
  end

  test "sorts transit durations when every route is reachable without destructive selection nil" do
    maps = FakeMaps.new({ "slow" => 900, "fast" => 100 })
    hiking = FakeHiking.new([trail("slow"), trail("fast")])
    results = search(maps: maps, hiking: hiking)
    assert_equal %w[fast slow], results.map(&:name)
    assert_equal({ lat: 47, lon: -122, maximum_length: 3 }, hiking.arguments)
    assert_equal "A & B / 東京", results.first.origin
  end

  test "filters unreachable routes and returns empty arrays consistently" do
    maps = FakeMaps.new({ "reachable" => 600, "unreachable" => nil })
    assert_equal ["reachable"], search(maps: maps, hiking: FakeHiking.new([trail("unreachable"), trail("reachable")])).map(&:name)
    assert_empty search(maps: maps, hiking: FakeHiking.new([trail("unreachable")]))
    assert_empty search(maps: maps, hiking: FakeHiking.new([]))
  end

  test "missing geocode is actionable validation failure" do
    maps = FakeMaps.new({}, location: nil)
    hiking = FakeHiking.new([])
    assert_raises(SearchErrors::InvalidInput) { search(maps: maps, hiking: hiking) }
    assert_nil hiking.arguments
    assert_empty maps.calls
  end

  test "never performs more than ten transit calls" do
    trails = (1..30).map { |index| trail(index.to_s) }
    maps = FakeMaps.new(trails.to_h { |item| [item.name, 600] })
    assert_equal 10, search(maps: maps, hiking: FakeHiking.new(trails)).length
    assert_equal 10, maps.calls.size
  end
end
