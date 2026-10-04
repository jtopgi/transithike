# A city's guide as GuideService writes it, for pages and tests that read guides.
module GuideFixtures
  SATURDAY = "2026-10-10T08:00:00-04:00".freeze

  def guide_trip(departure, arrival, legs)
    { departure: departure, arrival: arrival, legs: legs }
  end

  def guide_leg(mode, name, from, to, departure, arrival)
    { mode: mode, name: name, agency: "Metro-North", headsign: nil, from: nil, to: nil, from_name: from, to_name: to,
      departure: departure, arrival: arrival }
  end

  # Breakneck Ridge out and back, by the Hudson Line, and a plain-named loop near a reservoir.
  def guide_data(built_at: "2026-10-07T09:00:00Z")
    there = guide_trip("2026-10-10T12:12:00Z", "2026-10-10T13:40:00Z",
      [guide_leg("SUBURBAN", "Hudson Line", "Grand Central", "Breakneck Ridge", "2026-10-10T12:12:00Z", "2026-10-10T13:28:00Z")])
    back = guide_trip("2026-10-10T19:05:00Z", "2026-10-10T20:30:00Z",
      [guide_leg("SUBURBAN", "Hudson Line", "Cold Spring", "Grand Central", "2026-10-10T19:12:00Z", "2026-10-10T20:25:00Z")])
    last = guide_trip("2026-10-11T00:50:00Z", "2026-10-11T02:15:00Z",
      [guide_leg("SUBURBAN", "Hudson Line", "Cold Spring", "Grand Central", "2026-10-11T00:57:00Z", "2026-10-11T02:10:00Z")])
    {
      slug: "new-york-city", name: "New York City", origin: "Midtown Manhattan", built_at: built_at,
      departure_time: SATURDAY, return_by: "2026-10-10T23:00:00-04:00", complete: true,
      hikes: [
        { slug: "breakneck-ridge-trail", title: "Breakneck Ridge Trail", area: "Hudson Highlands State Park",
          trail: { name: "Breakneck Ridge Trail", summary: "A steep scramble above the Hudson.", latitude: 41.443,
            longitude: -73.978, length: 2.5, osm_id: 101, path: [[[41.443, -73.978], [41.46, -73.96]]],
            highlights: [{ kind: "viewpoint", name: "Breakneck Ridge" }, { kind: "peak", name: "Sugarloaf Mountain" }],
            notable: true, paved: 0.0, loop: false, duration: 5_880, transfers: 0, arrival: "2026-10-10T13:40:00Z",
            last_return: "2026-10-11T00:50:00Z", terrain: { climb: 380, relief: 360 }, score: 3.4, plan: "out_and_back",
            finish: nil, location: "Cold Spring, New York" },
          there: there, ways: { back: back, last: last, same_way: true, trips: [back, last] }, departures: [there],
          photos: [{ image_url: "https://upload.wikimedia.org/thumb/Breakneck.jpg/500px-Breakneck.jpg",
            file_url: "https://commons.wikimedia.org/wiki/File:Breakneck.jpg", credit: "Ann · CC BY 4.0",
            caption: "Breakneck Ridge view" }] },
        { slug: "white-trail-tarrytown-lakes", title: "White Trail (Tarrytown Lakes)", area: "Tarrytown Lakes",
          trail: { name: "White Trail", summary: "A walk around the lakes.", latitude: 41.08, longitude: -73.85,
            length: 3.0, osm_id: 202, path: [[[41.08, -73.85], [41.09, -73.84], [41.08, -73.85]]], highlights: [],
            notable: false, paved: 0.0, loop: true, duration: 3_600, transfers: 1, arrival: "2026-10-10T13:00:00Z",
            last_return: "2026-10-11T01:30:00Z", terrain: { climb: 40, relief: 30 }, score: 1.2, plan: "loop",
            finish: nil },
          there: nil, ways: {}, departures: [], photos: [] }
      ]
    }
  end

  # Writes the guide where GuideService reads guides, for the rest of the test.
  def write_guide(data = guide_data)
    directory = Pathname(Dir.mktmpdir("guides"))
    directory.join("#{data[:slug]}.json").write(JSON.generate(data))
    GuideService.directory = directory
  end
end
