require "openssl"
require "securerandom"

# Counts visits in Azure Application Insights from the server, with no cookies
# or anything else kept in visitors' browsers: pages people see, their
# searches, and visits from crawlers, each sent in the background after the
# response. Visitors are told apart for a day by a hash of their IP address and
# browser with a random salt that's replaced every day and only kept in memory,
# so no one can be followed from one day to the next. IP addresses are only
# sent for Application Insights to find the country and city, which it keeps
# instead of the address.
module VisitTracker
  # Crawlers, named for reports, by their user agents: the first that matches names one.
  CRAWLERS = [
    ["Google", /Google(?:bot|-InspectionTool|Other|-Extended|-Read-Aloud|-CloudVertexBot)|Storebot-Google|AdsBot-Google|APIs-Google|Mediapartners-Google/i],
    ["Bing", /bingbot|BingPreview|msnbot|adidxbot/i],
    ["ChatGPT", /GPTBot|OAI-SearchBot|ChatGPT-User/i],
    ["Claude", /ClaudeBot|Claude-User|Claude-SearchBot|anthropic-ai/i],
    ["Perplexity", /Perplexity(?:Bot|-User)/i],
    ["DuckDuckGo", /DuckDuckBot|DuckAssistBot/i],
    ["Apple", /Applebot/i],
    ["Yandex", /Yandex(?:Bot|Images|AccessibilityBot)/i],
    ["Baidu", /Baiduspider/i],
    ["Meta", /meta-external(?:agent|fetcher)|facebookexternalhit|FacebookBot/i],
    ["Amazon", /Amazonbot/i],
    ["Common Crawl", /CCBot/i],
    ["ByteDance", /Bytespider/i],
    ["Link previews", /Twitterbot|LinkedInBot|Slackbot|Discordbot|WhatsApp|TelegramBot|Pinterest|redditbot|Embedly|SkypeUriPreview|Iframely|Mastodon/i],
    ["Other bot", /bot|crawl|spider|slurp|scrape|fetch|curl|wget|python|httpx|Go-http-client|okhttp|axios|undici|java\/|libwww|HeadlessChrome|Lighthouse|PageSpeed|uptime|monitor/i]
  ].freeze
  # Azure's own checks that the site is up aren't visits.
  CHECKS = /AlwaysOn|HealthCheck|ReadyForRequest/i
  # Pages browsers load ahead of a click, which may never be seen.
  PREFETCH = /prefetch|prerender/i
  ENVELOPES = { "PageviewData" => "PageView", "EventData" => "Event" }.freeze
  # Visits wait in a queue of at most this many to be sent, and more are dropped.
  MAX_QUEUE = 1_000
  SALT_LOCK = Mutex.new

  class << self
    attr_writer :settings, :delivery

    # Application Insights' instrumentation key and where to send to, from its
    # connection string, or nil when there is none, and nothing is counted.
    def settings
      return @settings if defined?(@settings)

      @settings = parse(ENV["APPLICATIONINSIGHTS_CONNECTION_STRING"])
    end

    def parse(connection_string)
      fields = connection_string.to_s.split(";").filter_map { |pair| pair.split("=", 2).map(&:strip) if pair.include?("=") }.to_h
      key, endpoint = fields.values_at("InstrumentationKey", "IngestionEndpoint")
      { key: key, url: URI.join(endpoint, "v2/track").to_s } if key.present? && endpoint.to_s.start_with?("https://")
    rescue URI::Error
      nil
    end

    # Counts a response: a page a visitor sees, or any visit from a crawler.
    def response(request, response)
      return unless settings && request.get? && !request.user_agent.to_s.match?(CHECKS)

      if (crawler = crawler(request.user_agent))
        deliver(envelope(request, "EventData", name: "Crawler",
          properties: { crawler: crawler, path: request.path, status: response.status.to_s }))
      elsif response.successful? && response.media_type == "text/html" && !prefetch?(request)
        deliver(envelope(request, "PageviewData", name: request.path, url: "#{request.base_url}#{request.path}",
          properties: details(request)))
      end
    end

    # Counts something a visitor did, such as a search, with what's said about it.
    def event(request, name, **properties)
      return unless settings && !crawler(request.user_agent)

      deliver(envelope(request, "EventData", name: name,
        properties: details(request).merge(properties.compact.transform_values(&:to_s))))
    end

    # The crawler's name, or nil for a browser.
    def crawler(agent)
      return "Other bot" if agent.blank?

      CRAWLERS.find { |_, pattern| agent.match?(pattern) }&.first
    end

    # Anonymous, and different every day: a hash of the visitor's address and browser with the day's salt.
    def visitor(request)
      OpenSSL::HMAC.hexdigest("SHA256", salt, "#{client_ip(request)}|#{request.user_agent}")[0, 16]
    end

    # The visitor's IP address: App Service passes it on in headers, sometimes with a port.
    def client_ip(request)
      address = request.headers["X-Client-IP"].presence || request.headers["X-Forwarded-For"].to_s.split(",").first.presence ||
        request.ip
      address.to_s.strip.sub(/\A\[(.+)\](?::\d+)?\z/, '\1').sub(/\A(\d{1,3}(?:\.\d{1,3}){3}):\d+\z/, '\1').presence
    end

    private

    def envelope(request, type, **data)
      { name: "Microsoft.ApplicationInsights.#{ENVELOPES.fetch(type)}", time: Time.now.utc.iso8601(3), iKey: settings[:key],
        tags: { "ai.user.id" => visitor(request), "ai.location.ip" => client_ip(request), "ai.cloud.role" => "transithike" }.compact,
        data: { baseType: type, baseData: { ver: 2, **data } } }
    end

    # Where the visitor came from, and their device, browser, system, and language.
    def details(request)
      agent = request.user_agent.to_s
      { referrer: referrer(request), device: device(agent), browser: browser(agent), system: system(agent),
        language: request.headers["Accept-Language"].to_s[/\A\s*([a-z]{2,3}(?:-[A-Za-z]{2})?)\b/, 1] }.compact
    end

    # Another site's host name, without "www.".
    def referrer(request)
      host = URI.parse(request.referer).host if request.referer.present?
      host.downcase.delete_prefix("www.") if host.present? && host.casecmp?(request.host) == false
    rescue URI::InvalidURIError
      nil
    end

    def device(agent)
      return "Tablet" if agent.match?(/iPad|Tablet/i) || (agent.match?(/Android/i) && !agent.match?(/Mobile/i))

      agent.match?(/Mobi|iPhone|iPod/i) ? "Mobile" : "Desktop"
    end

    def browser(agent)
      case agent
      when %r{Edg(?:e|A|iOS)?/} then "Edge"
      when %r{OPR/|Opera} then "Opera"
      when %r{Firefox/|FxiOS} then "Firefox"
      when /SamsungBrowser/ then "Samsung Internet"
      when %r{Chrome/|CriOS} then "Chrome"
      when %r{Safari/} then "Safari"
      else "Other"
      end
    end

    def system(agent)
      case agent
      when /iPhone|iPad|iPod/ then "iOS"
      when /Android/ then "Android"
      when /Windows/ then "Windows"
      when /CrOS/ then "ChromeOS"
      when /Macintosh|Mac OS X/ then "macOS"
      when /Linux/ then "Linux"
      else "Other"
      end
    end

    def prefetch?(request)
      %w[Sec-Purpose Purpose X-Purpose X-Moz].any? { |header| request.headers[header].to_s.match?(PREFETCH) }
    end

    def salt
      SALT_LOCK.synchronize do
        today = Time.now.utc.to_date
        @salt = [today, SecureRandom.hex(32)] unless @salt&.first == today
        @salt.last
      end
    end

    # Sends in the background, so pages never wait, dropping what doesn't fit in the queue or fails.
    def deliver(envelope)
      return @delivery.call(envelope) if @delivery

      queue.post { send_now(envelope) }
    end

    def send_now(envelope)
      connection.post do |request|
        request.headers["Content-Type"] = "application/json"
        request.body = [envelope].to_json
      end
    rescue StandardError => error
      Rails.logger.warn("Visit not counted: #{error.class}")
    end

    def connection
      @connection ||= SearchHttp.connection(settings[:url], timeout: 5)
    end

    def queue
      @queue ||= Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: 1, max_queue: MAX_QUEUE,
        fallback_policy: :discard, idletime: 60)
    end
  end
end
