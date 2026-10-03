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

    # Free providers are busy at times, so a city whose search fails is tried again after a pause.
    pause = Integer(ENV.fetch("RETRY_PAUSE", "120"))
    written = guides.count do |guide|
      attempts = 0
      begin
        attempts += 1
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        data = GuideService.build(guide, previous: GuideService.previous(guide))
        kept = GuideService.write(guide, data)
        seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
        puts "#{guide.name}: #{data[:hikes].size} hikes in #{seconds}s#{kept ? '' : ', too few, so the last guide stays'}"
        kept
      rescue SearchErrors::UpstreamError, SearchErrors::InvalidInput => error
        if attempts < 2 && error.is_a?(SearchErrors::UpstreamError)
          puts "#{guide.name}: failed (#{error.message}), trying again in #{pause}s"
          sleep pause
          retry
        end
        puts "#{guide.name}: failed (#{error.message}), so the last guide stays"
        false
      end
    end
    puts "#{written} of #{guides.size} guides written to #{GuideService.directory}"
    # Lookups left running finish, and their pools stop, before Ruby exits, which can otherwise hang killing their threads.
    pools = Rails.configuration.x.then { |config| [config.provider_pool, config.overpass_pool] }
    pools.each(&:shutdown)
    pools.each { |pool| pool.wait_for_termination(60) }
    abort "No guide could be built" if written.zero?
  end
end
