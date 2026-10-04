require "test_helper"

class VisitsTest < ActionDispatch::IntegrationTest
  BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

  setup do
    @sent = []
    VisitTracker.settings = { key: "key-1", url: "https://ingest.example/v2/track" }
    VisitTracker.delivery = ->(envelope) { @sent << envelope }
  end

  teardown do
    VisitTracker.settings = nil
    VisitTracker.delivery = nil
  end

  def counted = @sent.map { |envelope| [envelope[:data][:baseType], envelope[:data][:baseData][:name]] }

  test "pages people see and crawlers' visits are counted, and Azure's checks aren't" do
    get root_path, headers: { "User-Agent" => BROWSER }
    get robots_path, headers: { "User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" }
    get "/up", headers: { "User-Agent" => "HealthCheck/1.0" }
    get root_path, headers: { "User-Agent" => "AlwaysOn" }

    assert_equal [["PageviewData", "/"], %w[EventData Crawler]], counted
    assert_equal "Google", @sent.last.dig(:data, :baseData, :properties, :crawler)
  end
end
