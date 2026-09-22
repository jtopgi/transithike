require "faraday"
require "json"

module SearchHttp
  MAX_RESPONSE_BYTES = 8 * 1024 * 1024

  def self.connection(url, timeout: 5)
    Faraday.new(url: url) do |http|
      http.options.open_timeout = 3
      http.options.timeout = timeout
      http.options.on_data = lambda do |chunk, received_bytes, env|
        if received_bytes > MAX_RESPONSE_BYTES
          raise SearchErrors::UpstreamError, "A search provider is unavailable. Please try again later."
        end

        env[:streaming_response_body] ||= String.new(encoding: Encoding::BINARY)
        env[:streaming_response_body] << chunk
      end
    end
  end

  def self.json
    response = yield
    body = response.env[:streaming_response_body] || response.body
    unless response.success? && body.is_a?(String) && body.bytesize <= MAX_RESPONSE_BYTES
      raise SearchErrors::UpstreamError, "A search provider is unavailable. Please try again later."
    end

    body = body.dup.force_encoding(Encoding::UTF_8)
    raise JSON::ParserError unless body.valid_encoding?

    data = JSON.parse(body)
    raise JSON::ParserError unless data.is_a?(Hash)

    data
  rescue Faraday::Error, JSON::ParserError
    raise SearchErrors::UpstreamError, "A search provider is unavailable. Please try again later."
  end

  def self.coordinates?(latitude, longitude)
    latitude.is_a?(Numeric) && longitude.is_a?(Numeric) &&
      latitude.finite? && longitude.finite? &&
      latitude.between?(-90, 90) && longitude.between?(-180, 180)
  end
end
