# Slots for requests to a provider that answers only so many at once, in place
# of a Concurrent::Semaphore. A free slot goes to the most urgent request
# waiting: first those a visitor's own request makes, then those of searches
# visitors wait on, and last background work, such as refreshing kept searches.
# Threads say how urgent their requests are with ProviderSlots.with_priority,
# and futures TrailsService starts are as urgent as the threads starting them.
class ProviderSlots
  VISITOR = 0
  SEARCH = 1
  BACKGROUND = 2
  KEY = :provider_priority

  # How urgent the current thread's requests are, BACKGROUND unless it says.
  def self.priority
    urgency = Thread.current[KEY]
    urgency = urgency.provider_priority if urgency.respond_to?(:provider_priority)
    urgency || BACKGROUND
  end

  # What the current thread's urgency comes from, to pass on to threads it starts.
  def self.urgency
    Thread.current[KEY]
  end

  # Runs the block with the thread's requests as urgent as urgency says: a
  # priority, or something whose provider_priority does, such as a station's
  # search, which visitors can come to wait on while it runs.
  def self.with_priority(urgency)
    previous = Thread.current[KEY]
    Thread.current[KEY] = urgency
    yield
  ensure
    Thread.current[KEY] = previous
  end

  def initialize(count)
    @free, @waiting, @lock, @turn = count, Array.new(BACKGROUND + 1, 0), Mutex.new, ConditionVariable.new
  end

  # Takes permits slots, once no more urgent request is waiting, waiting at
  # most timeout seconds, or not at all without one, and returns whether it did.
  def try_acquire(permits = 1, timeout = nil)
    take(permits, Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f)
  end

  # Takes permits slots, waiting as long as it takes.
  def acquire(permits = 1)
    take(permits, nil)
    nil
  end

  def release(permits = 1)
    @lock.synchronize do
      @free += permits
      @turn.broadcast
    end
    nil
  end

  def available_permits
    @lock.synchronize { @free }
  end

  # How many requests are waiting for slots.
  def waiting
    @lock.synchronize { @waiting.sum }
  end

  private

  # Waits until deadline, or as long as it takes without one.
  def take(permits, deadline)
    priority = self.class.priority
    @lock.synchronize do
      @waiting[priority] += 1
      begin
        until @free >= permits && @waiting.first(priority).sum.zero?
          left = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if left && !left.positive?

          @turn.wait(@lock, left)
        end
        @free -= permits
        true
      ensure
        @waiting[priority] -= 1
        # Less urgent requests may go ahead once this one isn't waiting.
        @turn.broadcast
      end
    end
  end
end
