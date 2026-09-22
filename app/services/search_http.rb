require "faraday"
require "json"

module SearchHttp
  MAX_RESPONSE_BYTES = 8 * 1024 * 1024

  def self.connection(url, timeout: 5)
    Faraday.new(url: url) do |http|
      http.options.open_timeout = 3
      http.options.timeout = timeout
    end
  end

  def self.json
    response = yield
    unless response.success? && response.body.is_a?(String) && response.body.bytesize <= MAX_RESPONSE_BYTES
      raise SearchErrors::UpstreamError, "A search provider is unavailable. Please try again later."
    end

    data = JSON.parse(response.body)
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
