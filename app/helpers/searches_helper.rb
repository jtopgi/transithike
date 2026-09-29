module SearchesHelper
  # Monthly page views of a route's park or natural area, and how they read.
  POPULARITY_LEVELS = [[2_000, "🔥", "Very popular"], [300, "👥", "Popular"]].freeze
  HIGHLIGHT_LABELS = {
    "waterfall" => ["💧", "Waterfall", "Waterfalls"],
    "peak" => ["⛰️", "Summit", "Summits"],
    "viewpoint" => ["🔭", "Viewpoint", "Viewpoints"]
  }.freeze

  # [icon, label, detail] chips for how well known a route's area is and the highlights on the way.
  def trail_chips(trail)
    views = trail.area&.dig(:monthly_views).to_i
    level = POPULARITY_LEVELS.find { |minimum, *| views >= minimum }
    chips = []
    if level
      chips << [level[1], level[2],
        "#{number_with_delimiter(views)} Wikipedia page views of #{trail.area[:title]} in the last 30 days"]
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
      chips << [icon, label, "#{highlights.one? ? one : many}#{": #{names.join(', ')}" if names.any?}"]
    end
    chips
  end

  # For example "Travel times for leaving tomorrow at 8:00 AM PDT, with a way back by 11 PM.",
  # with times kept on one line.
  def trip_times(result)
    "Travel times for #{departure_phrase(result.departure_time)}, with a way back by #{result.return_by.strftime('%-I %p')}."
      .gsub(/(\d) (AM|PM)\b( [A-Z]{2,5}\b)?/) { "#{$1}\u00a0#{$2}#{$3&.sub(' ', "\u00a0")}" }
  end

  # A time of day in the search's time zone, such as "6:21 PM".
  def clock(time, result)
    time.in_time_zone(result.departure_time.time_zone).strftime("%-I:%M %p")
  end

  # How long there is between arriving and the last trip back, such as "2 h 30 min" or "9 h".
  def stay_label(trail)
    hours, minutes = (stay_seconds(trail) / 60).divmod(60)
    minutes.zero? || hours >= 4 ? "#{hours} h" : "#{hours} h #{minutes} min"
  end

  def stay_seconds(trail)
    trail.last_return ? [(trail.last_return - trail.arrival).floor, 0].max : 0
  end

  # Where the page looks up the trains, buses, and ferries to take there and back.
  def trip_lookup_path(trail, result)
    place = result.place
    trip_path(from: "#{place.latitude.to_f},#{place.longitude.to_f}", to: "#{trail.latitude.to_f},#{trail.longitude.to_f}",
      leave: result.departure_time.utc.iso8601, back_by: result.return_by.utc.iso8601)
  end

  # For example "leaving now" or "leaving tomorrow at 8:00 AM PDT".
  def departure_phrase(departure_time)
    now = Time.current.in_time_zone(departure_time.time_zone)
    return "leaving now" if departure_time <= now + 15.minutes

    day = departure_time.to_date == now.to_date ? "today" : "tomorrow"
    "leaving #{day} at #{departure_time.strftime('%-I:%M %p %Z')}"
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
