module HikesHelper
  MODE_ICONS = {
    "BUS" => "🚌", "COACH" => "🚍", "TRAM" => "🚊", "SUBWAY" => "🚇", "FERRY" => "⛴️",
    "FUNICULAR" => "🚞", "AERIAL_LIFT" => "🚡", "AREAL_LIFT" => "🚡", "CABLE_CAR" => "🚡"
  }.freeze

  # Like the results page's: trains, including Transitous's METRO, which is an old name for suburban trains.
  def mode_icon(mode)
    MODE_ICONS[mode] || (mode.to_s.match?(/RAIL|SUBURBAN|LONG_DISTANCE|METRO/) ? "🚆" : "🚏")
  end

  # A time of day from an ISO 8601 time, such as "8:12 AM".
  def trip_clock(time, zone)
    Time.iso8601(time).in_time_zone(zone).strftime("%-I:%M %p") if time
  end

  # How long a trip rides, such as "1 h 15 min".
  def ride_label(trip)
    duration_label(Time.iso8601(trip[:arrival]) - Time.iso8601(trip[:departure]))
  end

  # Minutes walked from the last stop to where the trip ends, or nil.
  def walk_after(trip)
    last = Array(trip[:legs]).last
    return unless last&.dig(:arrival)

    minutes = ((Time.iso8601(trip[:arrival]) - Time.iso8601(last[:arrival])) / 60).round
    minutes if minutes.positive?
  end

  # A leg such as "Hudson Line from Grand Central to Cold Spring".
  def leg_label(leg)
    stops = [("from #{leg[:from_name]}" if leg[:from_name]), ("to #{leg[:to_name]}" if leg[:to_name])].compact
    [leg[:name] || leg[:mode].to_s.humanize, *stops].join(" ")
  end

  # Where trips back leave from, such as "Cold Spring", or nil.
  def boarding_stop(trip)
    Array(trip&.dig(:legs)).first&.dig(:from_name)
  end

  # Like the trip lookups, the details page for a search's hike, with trips
  # from its station and a link back to the search.
  def hike_details_path(trail, result)
    place, station = result.place, trail.station
    hike_path(route: trail.osm_id, plan: trail.plan || (trail.loop ? :loop : :out_and_back),
      from: "#{place.latitude.to_f},#{place.longitude.to_f}", to: "#{trail.latitude.to_f},#{trail.longitude.to_f}",
      finish: trail.finish&.join(","), leave: result.departure_time.utc.iso8601, back_by: result.return_by.utc.iso8601,
      tz: result.departure_time.time_zone.tzinfo.name, origin: place.name,
      station: station && "#{station.latitude.to_f},#{station.longitude.to_f}", station_name: station&.name)
  end
end
