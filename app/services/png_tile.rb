require "zlib"

# Just enough of PNG (https://www.w3.org/TR/png-3/) to read square map tiles:
# 8-bit images without interlacing, a row at a time. A tile that isn't one
# raises SearchErrors::UpstreamError with the provider's message.
module PngTile
  SIGNATURE = "\x89PNG\r\n\x1A\n".b

  # The tile's chunks by type, with its image data joined under "IDAT", once
  # its header says it's size by size pixels of 8 bits in the color type.
  def self.chunks(png, size:, color:, invalid:)
    raise SearchErrors::UpstreamError, invalid unless png.byteslice(0, 8) == SIGNATURE

    chunks, data, offset = {}, String.new(encoding: Encoding::BINARY), 8
    while offset + 8 <= png.bytesize
      length, type = png.unpack("Na4", offset: offset)
      break if type == "IEND"

      chunk = png.byteslice(offset + 8, length)
      raise SearchErrors::UpstreamError, invalid unless chunk&.bytesize == length

      type == "IDAT" ? data << chunk : chunks[type] = chunk
      offset += length + 12
    end
    raise SearchErrors::UpstreamError, invalid unless chunks["IHDR"]&.unpack("NNC5") == [size, size, 8, color, 0, 0, 0]

    chunks.merge("IDAT" => data)
  end

  # Yields each row of a size by size tile's image data, as an array of bytes,
  # bytes_per_pixel to a pixel, with PNG's filtering by the bytes before and
  # above undone, and its index.
  def self.each_row(data, size, bytes_per_pixel, invalid)
    stride = size * bytes_per_pixel
    rows = inflate(data, size * (stride + 1), invalid)
    above = Array.new(stride, 0)
    size.times do |row|
      start = row * (stride + 1)
      line = rows.byteslice(start + 1, stride).bytes
      unfilter(rows.getbyte(start), line, above, bytes_per_pixel, invalid)
      yield line, row
      above = line
    end
  end

  # Zlib data inflated to exactly size bytes.
  def self.inflate(data, size, invalid)
    inflated = String.new(encoding: Encoding::BINARY)
    zlib = Zlib::Inflate.new
    zlib.inflate(data) do |chunk|
      inflated << chunk
      raise SearchErrors::UpstreamError, invalid if inflated.bytesize > size
    end
    raise SearchErrors::UpstreamError, invalid unless zlib.finished? && inflated.bytesize == size

    inflated
  rescue Zlib::Error
    raise SearchErrors::UpstreamError, invalid
  ensure
    zlib&.close
  end

  def self.unfilter(filter, line, above, bytes_per_pixel, invalid)
    stride = line.size
    index = 0
    case filter
    when 0
    when 1
      index = bytes_per_pixel
      while index < stride
        line[index] = (line[index] + line[index - bytes_per_pixel]) & 255
        index += 1
      end
    when 2
      while index < stride
        line[index] = (line[index] + above[index]) & 255
        index += 1
      end
    when 3
      while index < stride
        left = index >= bytes_per_pixel ? line[index - bytes_per_pixel] : 0
        line[index] = (line[index] + (left + above[index]) / 2) & 255
        index += 1
      end
    when 4
      while index < stride
        left, up = index >= bytes_per_pixel ? line[index - bytes_per_pixel] : 0, above[index]
        corner = index >= bytes_per_pixel ? above[index - bytes_per_pixel] : 0
        guess = left + up - corner
        a, b, c = (guess - left).abs, (guess - up).abs, (guess - corner).abs
        line[index] = (line[index] + (a <= b && a <= c ? left : b <= c ? up : corner)) & 255
        index += 1
      end
    else
      raise SearchErrors::UpstreamError, invalid
    end
  end
end
