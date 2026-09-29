module SearchesHelper
  # Monthly page views of a route's park or natural area, and how they read.
  POPULARITY_LEVELS = [[2_000, "🔥", "Very popular"], [300, "👥", "Popular"]].freeze
  HIGHLIGHT_LABELS = {
    "waterfall" => ["💧", "Waterfall", "Waterfalls"],
    "peak" => ["⛰️", "Summit", "Summits"],
    "viewpoint" => ["🔭", "Viewpoint", "Viewpoints"]
  }.freeze
  MOSTLY_PAVED = 0.5

  # [icon, label, detail] chips for how well known a route's area is, the
  # highlights on the way, and whether it is mostly paved.
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
    if trail.paved.to_f >= MOSTLY_PAVED
      chips << ["🛣️", "Mostly paved", "About #{number_to_percentage(trail.paved * 100, precision: 0)} on paved paths or roads"]
    end
    chips
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
