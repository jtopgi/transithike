module SearchErrors
  class InvalidInput < StandardError; end
  class UpstreamError < StandardError; end
  # A response over SearchHttp::MAX_RESPONSE_BYTES, which callers can plan around.
  class ResponseTooLarge < UpstreamError; end
end
