require "faraday"

module SearchTestSupport
  def stub_connection(method, body, status: 200, &assert_request)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.public_send(method, "/") do |request|
        assert_request&.call(request)
        [status, { "Content-Type" => "application/json" }, body.is_a?(String) ? body : JSON.generate(body)]
      end
    end
    Faraday.new { |builder| builder.adapter :test, stubs }
  end

  def route_element(id: 123, latitude: 47.0, name: "Forest Loop")
    {
      "type" => "relation", "id" => id,
      "tags" => { "type" => "route", "route" => "hiking", "name" => name, "description" => "A wooded walk" },
      "members" => [
        { "type" => "way", "ref" => id, "role" => "",
          "geometry" => [{ "lat" => latitude, "lon" => -122.0 }, { "lat" => latitude + 0.01, "lon" => -122.0 }] }
      ]
    }
  end
end
