require "test_helper"

class ProviderSlotsTest < ActiveSupport::TestCase
  # Waits until count requests wait for the slots.
  def until_waiting(slots, count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until slots.waiting == count || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal count, slots.waiting
  end

  test "a free slot goes to the most urgent request waiting, however long the others have waited" do
    slots = ProviderSlots.new(1)
    slots.acquire
    served = Queue.new
    threads = [ProviderSlots::BACKGROUND, ProviderSlots::SEARCH, ProviderSlots::VISITOR].each_with_index.map do |priority, index|
      thread = Thread.new do
        ProviderSlots.with_priority(priority) do
          served << priority if slots.try_acquire(1, 5)
          slots.release
        end
      end
      until_waiting(slots, index + 1)
      thread
    end
    slots.release
    threads.each(&:join)

    assert_equal [ProviderSlots::VISITOR, ProviderSlots::SEARCH, ProviderSlots::BACKGROUND], Array.new(3) { served.pop }
    assert_equal 1, slots.available_permits
  end

  test "a request that became more urgent while waiting, as when a visitor comes to wait on its search, goes ahead" do
    slots = ProviderSlots.new(1)
    slots.acquire
    search = Struct.new(:provider_priority).new(ProviderSlots::BACKGROUND)
    served = Queue.new
    threads = [search, ProviderSlots::SEARCH].each_with_index.map do |urgency, index|
      thread = Thread.new do
        ProviderSlots.with_priority(urgency) do
          served << ProviderSlots.priority if slots.try_acquire(1, 5)
          slots.release
        end
      end
      until_waiting(slots, index + 1)
      thread
    end
    search.provider_priority = ProviderSlots::VISITOR
    slots.release
    threads.each(&:join)

    assert_equal [ProviderSlots::VISITOR, ProviderSlots::SEARCH], Array.new(2) { served.pop }
  end

  test "an urgency others wait on is raised to theirs, and never lowered" do
    shared = ProviderSlots::Shared.new(ProviderSlots::BACKGROUND)
    assert_equal ProviderSlots::BACKGROUND, shared.provider_priority
    shared.raise_to(ProviderSlots::SEARCH)
    shared.raise_to(ProviderSlots::BACKGROUND)
    assert_equal ProviderSlots::SEARCH, shared.provider_priority
    assert_equal ProviderSlots::VISITOR, ProviderSlots::Shared.new(ProviderSlots::VISITOR).tap { |own| own.raise_to(ProviderSlots::SEARCH) }.provider_priority
  end

  test "requests give up when no slot comes free in time, and then less urgent ones go ahead" do
    slots = ProviderSlots.new(2)
    assert slots.try_acquire(2)
    refute slots.try_acquire
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute ProviderSlots.with_priority(ProviderSlots::VISITOR) { slots.try_acquire(1, 0.05) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.05
    assert_equal 0, slots.waiting
    slots.release(2)
    assert slots.try_acquire(1, 0)
    assert_equal 1, slots.available_permits
  end

  test "threads are as urgent as what they work for, which can change, and the futures they start are too" do
    assert_equal ProviderSlots::BACKGROUND, ProviderSlots.priority
    search = Struct.new(:provider_priority).new(ProviderSlots::BACKGROUND)
    ProviderSlots.with_priority(search) do
      assert_equal ProviderSlots::BACKGROUND, TrailsService.start { ProviderSlots.priority }.value!
      # A visitor comes to wait on it.
      search.provider_priority = ProviderSlots::SEARCH
      assert_equal ProviderSlots::SEARCH, TrailsService.start { ProviderSlots.priority }.value!
    end
    assert_equal ProviderSlots::BACKGROUND, ProviderSlots.priority
  end
end
