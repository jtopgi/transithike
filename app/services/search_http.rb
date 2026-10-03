require "faraday"
require "json"

module SearchHttp
  MAX_RESPONSE_BYTES = 8 * 1024 * 1024
  UNAVAILABLE_MESSAGE = "A search provider is unavailable. Please try again later."
  # Community-run providers require clients to identify themselves with a contact.
  USER_AGENT = "TransitHike/0.1 (+https://github.com/jtopgi/transithike)"

  # Logs each failed request with its provider, which the errors people see leave out.
  class FailureLog < Faraday::Middleware
    def call(env)
      @app.call(env).on_complete do |done|
        Rails.logger.warn("#{done.url.host} responded #{done.status}") unless done.success?
      end
    rescue Faraday::Error, SearchErrors::UpstreamError => error
      Rails.logger.warn("#{env.url.host} failed: #{error.class.name.demodulize}")
      raise
    end
  end

  def self.connection(url, timeout: 5)
    Faraday.new(url: url, headers: { "User-Agent" => USER_AGENT }) do |http|
      http.use FailureLog
      http.options.open_timeout = 3
      http.options.timeout = timeout
      http.options.on_data = lambda do |chunk, received_bytes, env|
        if received_bytes > MAX_RESPONSE_BYTES
          raise SearchErrors::ResponseTooLarge, UNAVAILABLE_MESSAGE
        end

        env[:streaming_response_body] ||= String.new(encoding: Encoding::BINARY)
        env[:streaming_response_body] << chunk
      end
    end
  end

  def self.json(expected = Hash, &request)
    body = self.body(&request).dup.force_encoding(Encoding::UTF_8)
    raise JSON::ParserError, "response body is not valid UTF-8" unless body.valid_encoding?

    data = JSON.parse(body)
    raise JSON::ParserError unless data.is_a?(expected)

    data
  rescue JSON::ParserError
    raise SearchErrors::UpstreamError, UNAVAILABLE_MESSAGE
  end

  # The body of the block's successful response.
  def self.body
    response = yield
    body = response.env[:streaming_response_body] || response.body
    raise SearchErrors::UpstreamError, UNAVAILABLE_MESSAGE unless response.success? && body.is_a?(String)
    raise SearchErrors::ResponseTooLarge, UNAVAILABLE_MESSAGE if body.bytesize > MAX_RESPONSE_BYTES

    body
  rescue Faraday::Error
    raise SearchErrors::UpstreamError, UNAVAILABLE_MESSAGE
  end

  def self.coordinates?(latitude, longitude)
    latitude.is_a?(Numeric) && longitude.is_a?(Numeric) &&
      latitude.finite? && longitude.finite? &&
      latitude.between?(-90, 90) && longitude.between?(-180, 180)
  end
end
