# Solid Cache only treats a few database errors as misses, such as a lost
# connection, and raises the rest: a database that turns the app away, as a
# firewall does, or that hasn't got the cache's table yet. Searches work without
# the cache, only without keeping what they find, so any database error is a miss.
module FailOpenCache
  private

  def failsafe(method, returning: nil)
    super
  rescue ActiveRecord::ActiveRecordError => error
    ActiveSupport.error_reporter&.report(error, handled: true, severity: :warning)
    error_handler&.call(method: method, exception: error, returning: returning)
    returning
  end
end

SolidCache::Store.prepend(FailOpenCache)
