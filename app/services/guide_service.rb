require "json"

# Guides to day hikes by train from big cities: pages that search engines and
# AI assistants can read, built from a weekly search from each city rather than
# looked up as visitors ask. config/guides.yml lists the cities, and each
# city's guide is kept in db/guides/<slug>.json, which deploys download from
# the guides-data release that the weekly build publishes.
module GuideService
  CONFIG = Rails.root.join("config/guides.yml")
  # A new guide replaces the last one only when it has at least MIN_HIKES
  # hikes and at least KEEP_SHARE as many as the last one, so a provider's
  # bad day doesn't empty a city's pages.
  MIN_HIKES = 12
  KEEP_SHARE = 0.6
  # A photo lookup that fails is tried again after this long, since Commons is
  # slow at times, and builds give each lookup this long.
  PHOTO_RETRY_SECONDS = 10
  PHOTO_LOOKUP_SECONDS = 60
  # Names made only of these words, such as "White Trail" or "Northern Section",
  # need a place to tell them apart.
  GENERIC_WORDS = %w[
    trail trails loop loops path paths route section segment track way walk hike hiking nature main short long old new
    upper lower inner outer north south east west northern southern eastern western central white yellow red blue
    green orange purple pink black brown teal silver gold aqua violet gray grey blaze blazed spur connector link
    the a of and to
  ].to_set.freeze

  # A city with a guide, and the point in it that trips start from.
  Guide = Struct.new(:slug, :name, :origin, :latitude, :longitude, :time_zone, keyword_init: true) do
    def place
      Place.new(name: origin, latitude: latitude, longitude: longitude, time_zone: time_zone)
    end
  end
  # A city's guide as published: when it was built, the day it plans trips
  # for, the stations they leave from (none in guides built before trips left
  # from stations), and its hikes, most scenic first.
  Page = Struct.new(:guide, :built_at, :departure_time, :return_by, :stations, :hikes, keyword_init: true) do
    def hike(slug)
      hikes.find { |hike| hike.slug == slug }
    end
  end
  # A hike in a guide: its route, the trips there and back that TripPlans
  # plans, and photos of nature along it. title tells apart routes with plain
  # or shared names, as "White Trail (Garret Mountain)" does.
  Hike = Struct.new(:slug, :title, :trail, :area, :there, :ways, :departures, :photos, keyword_init: true)

  TRAIL_FIELDS = %i[name summary latitude longitude length osm_id path highlights notable paved loop duration transfers
    arrival last_return terrain score plan finish location station sunset].freeze

  class << self
    attr_writer :directory

    def directory
      @directory || Rails.root.join("db/guides")
    end

    # Every configured city, in order.
    def guides
      YAML.load_file(CONFIG).map { |slug, fields| Guide.new(slug: slug, **fields.symbolize_keys) }
    end

    # The published guides, in configured order.
    def pages
      guides.filter_map { |guide| page(guide.slug) }
    end

    # A city's published guide, or nil. Guides are read once, and again when their file changes.
    def page(slug)
      guide = guides.find { |candidate| candidate.slug == slug }
      file = directory.join("#{slug}.json") if guide
      return unless file&.file?

      cached = (@pages ||= Concurrent::Map.new)[file.to_s]
      return cached.last if cached && cached.first == file.mtime

      loaded = load(guide, JSON.parse(file.read, symbolize_names: true))
      @pages[file.to_s] = [file.mtime, loaded]
      loaded
    end

    # Searches from the city's major stations for next Saturday, then plans
    # each hike's trips from its station and finds its photos, as JSON-ready
    # data. Hikes keep the slugs they had in the last guide. With fresh, the
    # stations are searched again unless their kept searches are recent and
    # complete. Raises when the search fails.
    def build(guide, previous: nil, fresh: false, search: TrailsService, transit: TransitousService, photos: WikipediaService,
      places: PhotonService)
      place = guide.place
      result = search.search(origin: place, day: "saturday", fresh: fresh)
      trails = result.trails.sort_by { |trail| [-TrailsService.scenic(trail), -trail.score.to_f, trail.duration.to_i] }
      hikes = trails.map { |trail| hike_data(trail, place, result, transit, photos, places) }
      titled(hikes, previous)
      { slug: guide.slug, name: guide.name, origin: guide.origin, built_at: Time.current.utc.iso8601,
        departure_time: result.departure_time.iso8601, return_by: result.return_by.iso8601, complete: result.complete,
        stations: Array(result.stations).map(&:to_h), hikes: hikes }
    end

    # Builds a city's guide, trying once more after pause seconds when a
    # provider fails or some hikes can't be checked, as when Overpass is busy,
    # and saying how each try went with log. Returns the complete build, or else
    # the one with more hikes, or nil when neither worked.
    def rebuild(guide, pause:, log: ->(_line) {}, **providers)
      best = nil
      2.times do |attempt|
        sleep pause if attempt.positive?
        again = attempt.zero? ? ", trying again in #{pause}s" : ""
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          # The second try searches again where the first couldn't check every route.
          data = build(guide, previous: previous(guide), fresh: attempt.positive?, **providers)
        rescue SearchErrors::UpstreamError => error
          log.("#{guide.name}: failed (#{error.message})#{again}")
          next
        end
        seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
        rank = ->(built) { [built[:complete] ? 1 : 0, built[:hikes].size] }
        best = data if best.nil? || (rank.(data) <=> rank.(best)).positive?
        log.("#{guide.name}: #{data[:hikes].size} hikes in #{seconds}s#{data[:complete] ? '' : ", but some couldn't be checked#{again}"}")
        break if data[:complete]
      end
      best
    end

    # Writes a city's new guide unless it has too few hikes, returning whether it did.
    def write(guide, data)
      file = directory.join("#{guide.slug}.json")
      previous = JSON.parse(file.read, symbolize_names: true) if file.file?
      hikes = data[:hikes].size
      return false if hikes < MIN_HIKES || (previous && hikes < previous[:hikes].size * KEEP_SHARE)

      FileUtils.mkdir_p(directory)
      file.write("#{JSON.pretty_generate(data)}\n")
      true
    end

    def previous(guide)
      file = directory.join("#{guide.slug}.json")
      JSON.parse(file.read, symbolize_names: true) if file.file?
    end

    private

    def hike_data(trail, place, result, transit, photos, places)
      trail.location ||= optional { TrailsService.location(trail, place, places: places) }
      origin = trail.station&.place || place
      trips = optional { TripPlans.plan(trail, origin: origin, leave: result.departure_time, back_by: result.return_by, transit: transit) }
      gallery = gallery(trail, photos)
      fields = trail.to_h.slice(*TRAIL_FIELDS)
      fields[:station] = trail.station&.to_h
      fields[:arrival] = trail.arrival&.utc&.iso8601
      fields[:last_return] = trail.last_return&.utc&.iso8601
      fields[:sunset] = trail.sunset&.utc&.iso8601
      { trail: fields, area: gallery&.dig(:title)&.sub(/\s*\([^)]*\)\z/, ""), there: trips&.dig(:there),
        ways: (trips&.dig(:ways) || {}).slice(:back, :last, :same_way, :trips), departures: Array(trips&.dig(:departures)),
        photos: Array(gallery&.dig(:photos)) }
    end

    # Titles and slugs for the hikes, telling apart plain or shared names with
    # the natural area or station nearby, and keeping each route's last slug.
    def titled(hikes, previous)
      kept = Array(previous&.dig(:hikes)).to_h { |hike| [hike.dig(:trail, :osm_id), slug(hike[:slug].to_s).presence] }
      shared = hikes.map { |hike| hike.dig(:trail, :name).downcase }.tally
      taken = Set.new
      hikes.each do |hike|
        name = hike.dig(:trail, :name)
        # The station the train goes to, rather than a bus stop after it.
        legs = Array(hike.dig(:there, :legs))
        station = (legs.reverse.find { |leg| TransitousService::TRAIN_MODES.include?(leg[:mode]) } || legs.last)&.dig(:to_name)
        qualifier = hike[:area] || station
        plain = shared[name.downcase] > 1 || generic?(name)
        hike[:title] = plain && qualifier ? "#{name} (#{qualifier})" : name
        slug = kept[hike.dig(:trail, :osm_id)]
        slug = nil if slug && taken.include?(slug)
        slug ||= unique(slug(hike[:title]).presence || "hike", taken)
        taken << slug
        hike[:slug] = slug
      end
    end

    # Lowercase letters and digits joined by single hyphens, as the guides' routes accept.
    def slug(text)
      text.parameterize.tr("_", "-").squeeze("-").delete_prefix("-").delete_suffix("-")
    end

    def generic?(name)
      OverpassService.generic_name?(name) || name.downcase.scan(/[[:alpha:]]+/).all? { |word| GENERIC_WORDS.include?(word) }
    end

    def unique(slug, taken)
      return slug unless taken.include?(slug)

      (2..).lazy.map { |number| "#{slug}-#{number}" }.find { |candidate| !taken.include?(candidate) }
    end

    def load(guide, data)
      zone = ActiveSupport::TimeZone[guide.time_zone] || Time.zone
      hikes = data[:hikes].map do |hike|
        fields = hike[:trail].slice(*TRAIL_FIELDS)
        fields[:arrival] = Time.iso8601(fields[:arrival]) if fields[:arrival]
        fields[:last_return] = Time.iso8601(fields[:last_return]) if fields[:last_return]
        fields[:sunset] = Time.iso8601(fields[:sunset]) if fields[:sunset]
        fields[:plan] = fields[:plan]&.to_sym
        fields[:station] = Station.new(**fields[:station].slice(*Station.members)) if fields[:station]
        trail = OverpassService::Trail.new(**fields, origin: fields[:station]&.name || guide.origin)
        Hike.new(slug: hike[:slug], title: hike[:title], trail: trail, area: hike[:area], there: hike[:there],
          ways: hike[:ways] || {}, departures: Array(hike[:departures]), photos: Array(hike[:photos]))
      end
      stations = Array(data[:stations]).map { |station| Station.new(**station.slice(*Station.members)) }
      Page.new(guide: guide, built_at: Time.iso8601(data[:built_at]), departure_time: Time.iso8601(data[:departure_time]).in_time_zone(zone),
        return_by: Time.iso8601(data[:return_by]).in_time_zone(zone), stations: stations, hikes: hikes)
    end

    def optional
      yield
    rescue SearchErrors::UpstreamError
      nil
    end

    # The route's photos, looking again once when the lookup fails.
    def gallery(trail, photos)
      attempts = 0
      begin
        attempts += 1
        photos.photos_near(trail.photo_points, timeout: PHOTO_LOOKUP_SECONDS)
      rescue SearchErrors::UpstreamError
        return if attempts > 1

        sleep PHOTO_RETRY_SECONDS
        retry
      end
    end
  end
end
