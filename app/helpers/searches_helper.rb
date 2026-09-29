module SearchesHelper
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
