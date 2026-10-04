# Streams a search's progress and results to the results page as Server-Sent Events.
class SearchStreamsController < ApplicationController
  include ActionController::Live
  include SearchOrigin

  rate_limit to: 20, within: 1.minute, with: -> { too_many_searches }

  def show
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    start_stream
    # Typed places near the visitor's time zone come first, so "11101" finds Queens, not Costa Rica.
    result = TrailsService.search(origin: requested_origin(origin_text), day: requested_day,
      near: PhotonService.zone_center(requested_time_zone)) { |event, payload| send_found(event, payload) }
    send_event("done", count: result.trails.size, notices: notices(result))
    count_search(started, area: result.area, hikes: result.trails.size)
  rescue SearchErrors::InvalidInput, SearchErrors::UpstreamError => error
    send_event("failure", message: error.message)
    count_search(started, area: @result&.area, failed: true)
  rescue ActionController::Live::ClientDisconnected, IOError
    # The visitor left, so there is no one to tell.
  ensure
    response.stream.close
  end

  private

  def start_stream
    response.headers["Content-Type"] = "text/event-stream"
    # no-transform keeps Rack::Deflater and proxies from holding events back.
    response.headers["Cache-Control"] = "no-cache, no-transform"
    response.headers["X-Accel-Buffering"] = "no"
  end

  def send_found(event, payload)
    case event
    when :place
      @result = payload
      send_event("place", heading: "Day hikes by train from #{helpers.place_label(payload)}", departure: helpers.trip_times(payload),
        time_zone: payload.departure_time.time_zone.tzinfo.name)
    when :checking then send_event("checking", count: payload)
    when :trails
      send_event("trails", html: render_to_string(partial: "searches/trail", collection: payload, locals: { result: @result }))
    when :ranking then send_event("ranking", count: payload)
    when :update then send_event("update", trails: payload.map { |trail| trail_update(trail) })
    end
  end

  # What changes once highlights and terrain rank a route.
  def trail_update(trail)
    { id: trail.osm_id, score: trail.score, scenic: TrailsService.scenic(trail), climb: helpers.climb_label(trail),
      chips: render_to_string(partial: "searches/chips", locals: { trail: trail }) }
  end

  # Searches are counted with the area they start from, as "Seattle, Washington, United States", never the address.
  def count_search(started, **details)
    VisitTracker.event(request, "Search", day: requested_day, **details,
      seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round)
  rescue StandardError => error
    Rails.logger.warn("Search not counted: #{error.class}")
  end

  def notices(result)
    notices = []
    notices << "We couldn't check the way back for some hikes. Check the last trip back before you go." unless result.returns_checked
    notices << "Some hikes couldn't be checked just now. Search again later for more." unless result.complete
    notices
  end

  def send_event(name, data)
    response.stream.write("event: #{name}\ndata: #{data.to_json}\n\n")
  end

  def too_many_searches
    start_stream
    send_event("failure", message: "Too many searches in a short time. Please wait a minute and try again.")
    response.stream.close
  end
end
