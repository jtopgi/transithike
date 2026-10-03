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
    last = last_trip_time(hike)
    [
      "#{hike.title} is a #{miles}-mile hike (#{hike_plan_label(trail)})#{climb}.",
      "From #{page.guide.origin}, it's about #{each_way_label(hike)} each way#{", taking the #{train}" if train}.",
      ("On #{page.departure_time.strftime('%A')}s, the last trip back leaves at #{last.in_time_zone(page.departure_time.time_zone).strftime('%-I:%M %p')}." if last)
    ].compact.join(" ")
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
    latest = hikes.select { |hike| last_trip_time(hike) }.max_by { |hike| last_trip_time(hike) }
    if latest
      facts << ["Latest trip home", "from #{latest.title}, at #{last_trip_time(latest).in_time_zone(zone).strftime('%-I:%M %p')}"]
    end
    facts
  end
end
