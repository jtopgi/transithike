# What search engines and AI assistants read to find the site's pages.
class SeoController < ApplicationController
  # Crawlers may read every page, but not the lookups that pages make as they
  # load, which would ask the free providers to plan trips for them.
  PRIVATE_PATHS = %w[/search/stream /trip /photos /places /hike].freeze

  def robots
    expires_in 1.day, public: true
    render plain: [
      "User-agent: *", "Allow: /", *PRIVATE_PATHS.map { |path| "Disallow: #{path}" }, "", "Sitemap: #{sitemap_url}"
    ].join("\n") + "\n"
  end

  def sitemap
    @pages = GuideService.pages
    expires_in 1.hour, public: true
  end

  # A summary for AI assistants, as proposed at https://llmstxt.org.
  def llms
    @pages = GuideService.pages
    expires_in 1.hour, public: true
    render formats: :text, content_type: "text/plain"
  end
end
