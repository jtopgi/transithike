# Map tiles by key, as their lookups decode them, dropping the least recently
# used beyond a limit, for the lookups in a process to share.
class TileCache
  def initialize(limit)
    @limit, @tiles, @lock = limit, {}, Mutex.new
  end

  # The tile, or the block's, which is kept. Lookups of the same missing tile at once may each run the block.
  def fetch(key)
    found = @lock.synchronize { @tiles.key?(key) ? @tiles[key] = @tiles.delete(key) : nil }
    return found if found

    tile = yield
    @lock.synchronize do
      @tiles[key] = tile
      @tiles.delete(@tiles.each_key.first) while @tiles.size > @limit
    end
    tile
  end

  def size
    @lock.synchronize { @tiles.size }
  end

  def clear
    @lock.synchronize { @tiles.clear }
  end
end
