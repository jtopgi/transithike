require "test_helper"

class VisitTrackerTest < ActiveSupport::TestCase
  CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  setup do
    @sent = []
    VisitTracker.settings = { key: "key-1", url: "https://centralus-2.in.applicationinsights.azure.com/v2/track" }
    VisitTracker.delivery = ->(envelope) { @sent << envelope }
  end

  teardown do
    VisitTracker.settings = nil
    VisitTracker.delivery = nil
  end

  def request_for(path = "/", agent: CHROME, method: "GET", headers: {})
    env = Rack::MockRequest.env_for("https://transithike.example#{path}", method: method, "REMOTE_ADDR" => "10.0.0.1",
      "HTTP_USER_AGENT" => agent, **headers.to_h { |name, value| ["HTTP_#{name.upcase.tr('-', '_')}", value] })
    ActionDispatch::Request.new(env)
  end

  def response_for(status = 200, type = "text/html")
    ActionDispatch::Response.new(status, { "Content-Type" => "#{type}; charset=utf-8" })
  end

  test "a connection string gives the key and where to send" do
    assert_equal({ key: "abc", url: "https://centralus-2.in.applicationinsights.azure.com/v2/track" },
      VisitTracker.parse("InstrumentationKey=abc;IngestionEndpoint=https://centralus-2.in.applicationinsights.azure.com/;LiveEndpoint=x"))
    assert_nil VisitTracker.parse("InstrumentationKey=abc")
    assert_nil VisitTracker.parse("IngestionEndpoint=http://insecure.example/;InstrumentationKey=abc")
    assert_nil VisitTracker.parse(nil)
    assert_nil VisitTracker.parse("nonsense")
  end

  test "a page a visitor sees is counted with where they came from and their device, but not the query" do
    request = request_for("/search?origin=12+Main+St", agent: IPHONE,
      headers: { "X-Client-IP" => "203.0.113.9:51234", "Referer" => "https://www.google.com/search?q=hikes", "Accept-Language" => "en-US,en;q=0.9" })
    VisitTracker.response(request, response_for)

    page = @sent.sole
    assert_equal ["Microsoft.ApplicationInsights.PageView", "key-1", "PageviewData"], [page[:name], page[:iKey], page[:data][:baseType]]
    assert_equal({ ver: 2, name: "/search", url: "https://transithike.example/search",
      properties: { referrer: "google.com", device: "Mobile", browser: "Safari", system: "iOS", language: "en-US" } }, page[:data][:baseData])
    # The address goes only to find the country and city, and the visitor is a hash.
    assert_equal "203.0.113.9", page[:tags]["ai.location.ip"]
    assert_match(/\A\h{16}\z/, page[:tags]["ai.user.id"])
    refute_includes page.to_json, "Main"
  end

  test "lookups, failures, prefetches, other methods, and Azure's checks aren't page views" do
    VisitTracker.response(request_for("/trip"), response_for(200, "application/json"))
    VisitTracker.response(request_for("/missing"), response_for(404))
    VisitTracker.response(request_for("/", headers: { "Sec-Purpose" => "prefetch;prerender" }), response_for)
    VisitTracker.response(request_for("/", method: "HEAD"), response_for)
    VisitTracker.response(request_for("/", agent: "AlwaysOn"), response_for)
    VisitTracker.response(request_for("/", agent: "HealthCheck/1.0"), response_for)
    assert_empty @sent

    VisitTracker.settings = nil
    VisitTracker.response(request_for, response_for)
    assert_empty @sent
  end

  test "crawlers are counted by name on any page or file, not as visitors" do
    { "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" => "Google",
      "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)" => "Bing",
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)" => "ChatGPT",
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)" => "Claude",
      "Mozilla/5.0 (compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)" => "Perplexity",
      "facebookexternalhit/1.1" => "Meta", "Slackbot-LinkExpanding 1.0" => "Link previews",
      "curl/8.5.0" => "Other bot", "" => "Other bot" }.each do |agent, name|
      assert_equal name, VisitTracker.crawler(agent), agent
    end
    assert_nil VisitTracker.crawler(CHROME)
    assert_nil VisitTracker.crawler(IPHONE)

    VisitTracker.response(request_for("/robots.txt", agent: "Mozilla/5.0 (compatible; Googlebot/2.1)"), response_for(200, "text/plain"))
    crawl = @sent.sole
    assert_equal ["Microsoft.ApplicationInsights.Event", "Crawler"], [crawl[:name], crawl[:data][:baseData][:name]]
    assert_equal({ crawler: "Google", path: "/robots.txt", status: "200" }, crawl[:data][:baseData][:properties])
  end

  test "visitors are told apart for a day, and can't be followed to the next" do
    travel_to Time.utc(2026, 10, 3, 12) do
      first = VisitTracker.visitor(request_for(headers: { "X-Client-IP" => "203.0.113.9" }))
      assert_equal first, VisitTracker.visitor(request_for(headers: { "X-Client-IP" => "203.0.113.9" }))
      refute_equal first, VisitTracker.visitor(request_for(headers: { "X-Client-IP" => "198.51.100.4" }))
      refute_equal first, VisitTracker.visitor(request_for(agent: IPHONE, headers: { "X-Client-IP" => "203.0.113.9" }))
      travel 1.day
      refute_equal first, VisitTracker.visitor(request_for(headers: { "X-Client-IP" => "203.0.113.9" }))
    end
  end

  test "addresses come from App Service's headers, without ports" do
    assert_equal "203.0.113.9", VisitTracker.client_ip(request_for(headers: { "X-Forwarded-For" => "203.0.113.9:443, 10.0.0.2" }))
    assert_equal "2001:db8::1", VisitTracker.client_ip(request_for(headers: { "X-Client-IP" => "[2001:db8::1]:51234" }))
    assert_equal "10.0.0.1", VisitTracker.client_ip(request_for)
  end

  test "searches are counted with what's said about them, but not crawlers'" do
    VisitTracker.event(request_for("/search/stream"), "Search", area: "Seattle, Washington, United States", hikes: 12, failed: nil)
    search = @sent.sole[:data][:baseData]
    assert_equal ["Search", "Seattle, Washington, United States", "12", "Desktop"],
      [search[:name], *search[:properties].values_at(:area, :hikes, :device)]
    refute search[:properties].key?(:failed)

    VisitTracker.event(request_for("/search/stream", agent: "curl/8.5.0"), "Search", area: "Seattle")
    assert_equal 1, @sent.size
  end
end
