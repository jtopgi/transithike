module GuidesHelper
  # A script tag of structured data that search engines read.
  def structured_data(data)
    tag.script(ERB::Util.json_escape(data.to_json).html_safe, type: "application/ld+json")
  end

  def breadcrumbs_data(crumbs)
    { "@context" => "https://schema.org", "@type" => "BreadcrumbList",
      "itemListElement" => crumbs.each_with_index.map do |(name, url), index|
        { "@type" => "ListItem", "position" => index + 1, "name" => name, "item" => url }
      end }
  end

  # The last trip back's departure as a Time, or nil.
  def last_trip_time(hike)
    departure = hike.ways&.dig(:last, :departure)
    departure ? Time.iso8601(departure) : hike.trail.last_return
  end

  # Whether sunset is the hike's deadline rather than the last trip back.
  def sunset_first?(hike)
    TripPlans.sunset_first?(hike.trail.sunset, last_trip_time(hike))
  end

  # The first trip back after sunset, for hiking until then, where sunset is the hike's deadline, or nil.
  def after_sunset_trip(hike)
    TripPlans.until_sunset(hike.ways || {}, hike.trail.sunset)[:after_sunset]
  end

  # The train that rides longest on the way there, such as "Hudson train to Cold Spring", or nil.
  # Lines are named "Hudson" or "Port Jefferson Branch", so they're called trains.
  def main_train(hike)
    legs = Array(hike.there&.dig(:legs))
    train = legs.select { |leg| leg[:mode].to_s.match?(/RAIL|SUBURBAN|LONG_DISTANCE|METRO/) }
      .max_by { |leg| leg[:arrival] && leg[:departure] ? Time.iso8601(leg[:arrival]) - Time.iso8601(leg[:departure]) : 0 }
    return unless train

    [train[:name] ? "#{train[:name]} train" : "Train", ("to #{train[:to_name]}" if train[:to_name])].compact.join(" ")
  end

  # The one-way ride there, such as "1 h 20 min", from the planned trip or the search's estimate.
  def each_way_label(hike)
    hike.there ? ride_label(hike.there) : duration_label(hike.trail.duration, approximate: true)
  end

  # A sentence about the hike for its guide page and for search engines.
  def hike_summary(hike, page)
    trail = hike.trail
    miles = number_with_precision(TrailsService.hike_miles(trail), precision: 1)
    climb = " that climbs about #{feet(trail.terrain[:climb])}" if trail.terrain && trail.terrain[:climb].to_i >= 15
    train = main_train(hike)
    clock = ->(time) { time.in_time_zone(page.departure_time.time_zone).strftime("%-I:%M %p") }
    last = last_trip_time(hike)
    # Trips back after sunset are only for staying after dark, so the first of them is the one told.
    departure = after_sunset_trip(hike)&.dig(:departure) if sunset_first?(hike)
    dusk = Time.iso8601(departure) if departure
    back = if dusk && dusk != last
      "the first trip back after sunset leaves at #{clock.(dusk)}"
    elsif last && (dusk || !sunset_first?(hike))
      "the last trip back leaves at #{clock.(last)}"
    end
    [
      "#{hike.title} is a #{miles}-mile hike#{" near #{trail.location}" if trail.location} (#{hike_plan_label(trail)})#{climb}.",
      "From #{trail.station&.name || page.guide.origin}, it's about #{each_way_label(hike)} each way#{", taking the #{train}" if train}.",
      ("On #{page.departure_time.strftime('%A')}s, #{back}." if back)
    ].compact.join(" ")
  end

  # Where a guide's trips leave from, such as "Grand Central, Penn Station, and
  # Hoboken", or for guides built before trips left from stations, the point in
  # the city they left from.
  def guide_origin(page)
    page.stations.present? ? page.stations.map(&:name).to_sentence : page.guide.origin
  end

  # Facts about a city's hikes, as [label, text] pairs.
  def guide_facts(page)
    hikes = page.hikes
    zone = page.departure_time.time_zone
    facts = []
    closest = hikes.min_by { |hike| hike.trail.duration.to_i }
    facts << ["Closest", "#{closest.title}, about #{each_way_label(closest)} each way"] if closest
    views = hikes.select { |hike| hike.trail.terrain }.max_by { |hike| hike.trail.terrain[:climb].to_i }
    facts << ["Biggest climb", "#{views.title}, about #{feet(views.trail.terrain[:climb])}"] if views && views.trail.terrain[:climb].to_i >= 100
    falls = hikes.select { |hike| Array(hike.trail.highlights).any? { |highlight| highlight[:kind] == "waterfall" } }
    facts << ["Waterfalls", falls.first(3).map(&:title).to_sentence] if falls.any?
    # Every hike is done by sunset, which is much the same across the city.
    sunset = Daylight.sunset(page.departure_time, page.guide.latitude, page.guide.longitude)
    if sunset && sunset > page.departure_time
      facts << ["Sunset", "#{sunset.in_time_zone(zone).strftime('%-I:%M %p')}, and every hike is timed to be done by then"]
    end
    facts
  end
end
