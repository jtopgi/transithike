namespace :guides do
  desc "Build the day-hike guides for the cities in config/guides.yml (or CITIES=slug,slug) into db/guides"
  task build: :environment do
    # Each city's line shows as it finishes, with the time, in a workflow's log.
    $stdout.sync = true
    # Lookups are shared within a build, as they are within the server.
    Rails.cache = ActiveSupport::Cache::MemoryStore.new(size: 256.megabytes)
    only = ENV["CITIES"].to_s.split(",").map(&:strip).presence
    guides = GuideService.guides.select { |guide| only.nil? || only.include?(guide.slug) }
    abort "No guides match CITIES=#{ENV['CITIES']}" if guides.empty?

    # Free providers are busy at times, so a city whose search fails or is incomplete is tried again after a pause,
    # and Overpass limits how much each address asks, so cities are a minute apart.
    pause = Integer(ENV.fetch("RETRY_PAUSE", "120"))
    between = Integer(ENV.fetch("CITY_PAUSE", "60"))
    written = guides.each_with_index.count do |guide, index|
      sleep between if index.positive?
      data = GuideService.rebuild(guide, pause: pause, log: ->(line) { puts line })
      kept = data && GuideService.write(guide, data)
      puts "#{guide.name}: #{data ? 'too few hikes' : 'no guide built'}, so the last guide stays" unless kept
      kept
    rescue SearchErrors::InvalidInput => error
      puts "#{guide.name}: failed (#{error.message}), so the last guide stays"
      false
    end
    puts "#{written} of #{guides.size} guides written to #{GuideService.directory}"
    # Lookups left running finish, and their pools stop, before Ruby exits, which can otherwise hang killing their threads.
    pools = Rails.configuration.x.then { |config| [config.provider_pool, config.overpass_pool] }
    pools.each(&:shutdown)
    pools.each { |pool| pool.wait_for_termination(60) }
    abort "No guide could be built" if written.zero?
  end
end
