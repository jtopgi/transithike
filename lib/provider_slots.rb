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
  # While visitors are around, background work leaves the reserve free for
  # them, so their requests don't wait behind its slow ones: for this long
  # after a more urgent request last took a slot.
  RESERVE_SECONDS = 5 * 60

  # How urgent the current thread's requests are, BACKGROUND unless it says.
  def self.priority
    priority_of(Thread.current[KEY])
  end

  # The priority an urgency says now.
  def self.priority_of(urgency)
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

  # An urgency that others waiting on its work can raise, as when a visitor's
  # search waits on a lookup a background search started.
  class Shared
    def initialize(urgency)
      @urgency, @raised = urgency, Concurrent::AtomicReference.new(BACKGROUND)
    end

    def provider_priority
      [ProviderSlots.priority_of(@urgency), @raised.get].min
    end

    def raise_to(priority)
      @raised.update { |raised| [raised, priority].min }
    end
  end

  # A request waiting for slots, with what its urgency comes from.
  Waiter = Struct.new(:urgency)

  def initialize(count, reserve: 0)
    @free, @reserve, @waiters, @lock, @turn = count, reserve, Set.new.compare_by_identity, Mutex.new, ConditionVariable.new
    @urgent_at = nil
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
    @lock.synchronize { @waiters.size }
  end

  private

  # Waits until deadline, or as long as it takes without one. Each waiter's
  # priority is read each time it's compared, so one that became more urgent
  # while waiting, as when a visitor comes to wait on its search, goes ahead.
  def take(permits, deadline)
    waiter = Waiter.new(Thread.current[KEY])
    @lock.synchronize do
      @waiters << waiter
      begin
        until @free >= permits && first?(waiter) && room?(waiter, permits)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          left = deadline && deadline - now
          return false if left && !left.positive?

          # Kept out by the reserve, it looks again once the reserve lapses.
          lapse = @urgent_at + RESERVE_SECONDS - now if reserving?
          @turn.wait(@lock, [left, lapse].compact.min)
        end
        @free -= permits
        @urgent_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if self.class.priority_of(waiter.urgency) < BACKGROUND
        true
      ensure
        @waiters.delete(waiter)
        # Less urgent requests may go ahead once this one isn't waiting.
        @turn.broadcast
      end
    end
  end

  # Whether the waiter may take permits slots: background work leaves the
  # reserve free while more urgent requests have taken slots lately.
  def room?(waiter, permits)
    self.class.priority_of(waiter.urgency) < BACKGROUND || !reserving? || @free - permits >= @reserve
  end

  def reserving?
    @reserve.positive? && @urgent_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @urgent_at < RESERVE_SECONDS
  end

  # Whether no request waiting is more urgent than the waiter.
  def first?(waiter)
    priority = self.class.priority_of(waiter.urgency)
    @waiters.none? { |other| self.class.priority_of(other.urgency) < priority }
  end
end
