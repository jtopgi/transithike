module SearchErrors
  class InvalidInput < StandardError; end
  class UpstreamError < StandardError; end
  # A response over SearchHttp::MAX_RESPONSE_BYTES, which callers can plan around.
  class ResponseTooLarge < UpstreamError; end
  # No query slot was free for a provider that limits queries at once.
  class ProviderBusy < UpstreamError; end
end
