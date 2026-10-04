# Solid Cache only treats a few database errors as misses, such as a lost
# connection, and raises the rest: a database that turns the app away, as a
# firewall does, or that hasn't got the cache's table yet. Searches work without
# the cache, only without keeping what they find, so any database error is a
# miss. A database that can't be reached is left alone for PAUSE_SECONDS, so
# that each lookup doesn't wait out the connection's timeout meanwhile.
module FailOpenCache
  PAUSE_SECONDS = 30
  UNREACHABLE = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::AdapterTimeout].freeze

  private

  def failsafe(method, returning: nil)
    return returning if unreachable?

    super(method, returning: returning) do
      yield
    rescue *UNREACHABLE
      @unreachable_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PAUSE_SECONDS
      raise
    end
  rescue ActiveRecord::ActiveRecordError => error
    ActiveSupport.error_reporter&.report(error, handled: true, severity: :warning)
    error_handler&.call(method: method, exception: error, returning: returning)
    returning
  end

  def unreachable?
    @unreachable_until && Process.clock_gettime(Process::CLOCK_MONOTONIC) < @unreachable_until
  end
end

SolidCache::Store.prepend(FailOpenCache)
