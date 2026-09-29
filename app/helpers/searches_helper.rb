module SearchesHelper
  # How far a route's high point stands above the land around it, or how far
  # it climbs, in meters, for its views to read as big or as views at all.
  VIEW_LEVELS = [[300, "Big views"], [150, "Views"]].freeze
  HIGHLIGHT_LABELS = {
    "waterfall" => ["💧", "Waterfall", "Waterfalls"],
    "peak" => ["⛰️", "Summit", "Summits"],
    "viewpoint" => ["🔭", "Viewpoint", "Viewpoints"]
  }.freeze
  FEET_PER_METER = 3.28084

  # The route's middle, then points a sixth of the way from each end, as
  # "latitude,longitude|..." to about 1 km, where photos taken along it are looked for.
  def photo_points(trail)
    points = Array(trail.path).flatten(1)
    along = [1.0 / 6, 5.0 / 6].map { |share| points[(share * (points.size - 1)).round] } if points.size > 1
    [trail.midpoint, *along].map { |latitude, longitude| "#{latitude.round(2)},#{longitude.round(2)}" }.uniq.join("|")
  end

  # [icon, label, detail] chips for a route's views and the highlights on the way.
  def trail_chips(trail)
    chips = []
    relief, climb = trail.terrain&.values_at(:relief, :climb)
    level = VIEW_LEVELS.find { |minimum, _| [relief.to_i, climb.to_i].max >= minimum }
    if level
      chips << ["🌄", level.last, "Its high point stands about #{feet(relief)} above the land within about a mile, " \
        "and it climbs about #{feet(climb)}"]
    end
    grouped = Array(trail.highlights).group_by { |highlight| highlight[:kind] }
    HIGHLIGHT_LABELS.each do |kind, (icon, one, many)|
      next unless (highlights = grouped[kind])

      names = highlights.filter_map { |highlight| highlight[:name] }
      label = if names.any?
        highlights.one? ? names.first : "#{names.first} +#{highlights.size - 1}"
      else
        highlights.one? ? one : "#{highlights.size} #{many.downcase}"
      end
      details = highlights.filter_map { |highlight| highlight_detail(highlight) }
      chips << [icon, label, "#{highlights.one? ? one : many}#{": #{details.join(', ')}" if details.any?}"]
    end
    chips
  end

  # For example "Kaaterskill Falls (80 m tall, on Wikipedia)", or nil for an unnamed highlight with nothing to add.
  def highlight_detail(highlight)
    notes = [("#{highlight[:height].round} m tall" if highlight[:height]), ("on Wikipedia" if highlight[:notable])].compact
    return highlight[:name] if notes.empty?

    "#{highlight[:name] || 'unnamed'} (#{notes.join(', ')})"
  end

  # For example "≈ 1,150 ft", how far a route climbs, or nil before its terrain is known.
  def climb_label(trail)
    "≈ #{feet(trail.terrain[:climb])}" if trail.terrain
  end

  # Meters as feet, to the nearest 50, such as "1,150 ft".
  def feet(meters)
    "#{number_with_delimiter((meters.to_f * FEET_PER_METER / 50).round * 50)} ft"
  end

  # For example "Saturday, October 3, leaving at 8:00 AM EDT, with a way back by 11 PM.",
  # with times kept on one line.
  def trip_times(result)
    "#{departure_phrase(result.departure_time).upcase_first}, with a way back by #{result.return_by.strftime('%-I %p')}."
      .gsub(/(\d) (AM|PM)\b( [A-Z]{2,5}\b)?/) { "#{$1}\u00a0#{$2}#{$3&.sub(' ', "\u00a0")}" }
  end

  # A time of day in the search's time zone, such as "6:21 PM".
  def clock(time, result)
    time.in_time_zone(result.departure_time.time_zone).strftime("%-I:%M %p")
  end

  # How long there is between arriving and the last trip back, such as "2 h 30 min", "45 min", or "9 h".
  def stay_label(trail)
    seconds = stay_seconds(trail)
    seconds >= 4.hours ? "#{seconds / 1.hour} h" : duration_label(seconds)
  end

  def stay_seconds(trail)
    trail.last_return ? [(trail.last_return - trail.arrival).floor, 0].max : 0
  end

  # Where the page looks up the trains there and back, and when they leave:
  # the way back is the first after hiking for the time the search requires.
  def trip_lookup_path(trail, result)
    place = result.place
    trip_path(from: "#{place.latitude.to_f},#{place.longitude.to_f}", to: "#{trail.latitude.to_f},#{trail.longitude.to_f}",
      leave: result.departure_time.utc.iso8601, back_by: result.return_by.utc.iso8601,
      hike: (TrailsService.required_hours(trail) * 60).round)
  end

  # A length of time such as "4 h 35 min", "2 h", or "50 min", in steps of five
  # minutes when approximate.
  def duration_label(seconds, approximate: false)
    minutes = (seconds / 60.0).round
    minutes = (minutes / 5.0).round * 5 if approximate
    hours, minutes = minutes.divmod(60)
    [("#{hours} h" if hours.positive?), ("#{minutes} min" if minutes.positive? || hours.zero?)].compact.join(" ")
  end

  # For example "today, leaving now" or "Saturday, October 3, leaving at 8:00 AM EDT".
  def departure_phrase(departure_time)
    now = Time.current.in_time_zone(departure_time.time_zone)
    day = departure_time.to_date == now.to_date ? "today" : departure_time.strftime("%A, %B %-d")
    return "#{day}, leaving now" if departure_time <= now + 15.minutes

    "#{day}, leaving at #{departure_time.strftime('%-I:%M %p %Z')}"
  end

  # The weekend day the search box offers: the one asked for, or else whichever
  # comes next where the visitor is. The page corrects it from the device's clock.
  def trip_day
    return requested_day if requested_day

    zone = ActiveSupport::TimeZone[requested_time_zone] if requested_time_zone
    TrailsService.trip_date(Time.current.in_time_zone(zone || Time.zone)).saturday? ? "saturday" : "sunday"
  end

  def place_label(result)
    return result.place.name if result.place.name

    result.area ? "your location in #{result.area}" : "your location"
  end

  def transfers_label(transfers)
    case transfers
    when nil then "on foot"
    when 0 then "direct"
    else pluralize(transfers, "transfer")
    end
  end

  def directions_url(trail)
    # Without an origin, Google Maps starts from the device's own location.
    params = { api: 1, origin: trail.origin, destination: "#{trail.latitude},#{trail.longitude}", travelmode: "transit" }
    "https://www.google.com/maps/dir/?#{URI.encode_www_form(params.compact)}"
  end
end
