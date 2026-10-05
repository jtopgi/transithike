# Transitous's list of the stops transit reaches, read as it arrives a stop at
# a time, since from a big city's station it lists a few hundred thousand, over
# 100 MB of them from London. The list is the response's "all" array of
# {"place":{...},"duration":minutes,"k":rides} objects, so every object but the
# last ends where the text between two of them begins, which a JSON string
# can't hold, as the quotes in it would be escaped. Each stop is given to the
# block as a parsed JSON object, whatever it holds. Raises
# SearchErrors::UpstreamError when the response isn't such a list.
class StopList
  START = '"all":['.b.freeze
  BETWEEN = '},{"place":'.b.freeze
  # The origin's place comes before the list, and each stop takes a few hundred
  # bytes, so far more than this without either means it isn't such a list.
  MAX_UNREAD_BYTES = 256 * 1024
  INVALID = "The transit provider returned an invalid response.".freeze

  def initialize(&each_stop)
    @each_stop = each_stop
    @buffer = String.new(encoding: Encoding::BINARY)
    @offset = 0
    @started = false
  end

  # Reads the next part of the response.
  def <<(chunk)
    @buffer << chunk.b
    @started ||= start
    if @started
      while (boundary = @buffer.index(BETWEEN, @offset))
        stop(@buffer.byteslice(@offset, boundary + 1 - @offset))
        @offset = boundary + 2
      end
      @buffer = @buffer.byteslice(@offset..)
      @offset = 0
    end
    raise SearchErrors::UpstreamError, INVALID if @buffer.bytesize > MAX_UNREAD_BYTES

    self
  end

  # Reads the last stop, once the whole response has been read.
  def finish
    raise SearchErrors::UpstreamError, INVALID unless @started
    return if @buffer.start_with?("]")

    # The list ends after its last stop, at the first "}]" that ends one.
    position = 0
    while (close = @buffer.index("}]", position))
      last = parse(@buffer.byteslice(0, close + 1))
      return @each_stop.call(last) if last

      position = close + 1
    end
    raise SearchErrors::UpstreamError, INVALID
  end

  private

  def start
    found = @buffer.index(START)
    return false unless found

    @offset = found + START.bytesize
    true
  end

  def stop(text)
    reached = parse(text)
    raise SearchErrors::UpstreamError, INVALID unless reached

    @each_stop.call(reached)
  end

  def parse(text)
    reached = JSON.parse(text)
    reached if reached.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end
end
