require "test_helper"

class CacheFailsafeTest < ActiveSupport::TestCase
  # The cache's database calls, failing with error, as a database that turns
  # the app away does, and counted in calls.
  def failing(error = ActiveRecord::NoDatabaseError.new('no pg_hba.conf entry for host, database "transithike_production"'),
    calls: [])
    entry = SolidCache::Entry
    originals = %i[read read_multi write write_multi lock_and_write].to_h { |name| [name, entry.method(name)] }
    originals.each_key do |name|
      entry.define_singleton_method(name) do |*, **|
        calls << name
        raise error
      end
    end
    yield
  ensure
    originals&.each { |name, original| entry.define_singleton_method(name, original) }
  end

  test "the database cache misses, rather than failing, whatever the database says" do
    store = SolidCache::Store.new(namespace: "failsafe")
    failing do
      assert_nil store.read("hikes")
      assert_equal({}, store.read_multi("a", "b"))
      assert_not store.write("hikes", 1)
      assert_nil store.increment("visits")
      assert_equal 2, store.fetch("hikes") { 2 }
    end
    assert store.write("hikes", 3)
    assert_equal 3, store.read("hikes")
  end

  test "a database without the cache's table misses too, though writing raises Active Record's ArgumentError" do
    store = SolidCache::Store.new(namespace: "no-table")
    failing(ArgumentError.new("No unique index found for key_hash")) do
      assert_not store.write("hikes", 1)
      assert_equal 2, store.fetch("hikes") { 2 }
    end
  end

  test "a database that can't be reached is left alone for a while, so lookups don't each wait for it" do
    store = SolidCache::Store.new(namespace: "unreachable")
    calls = []
    stub_const(FailOpenCache, :PAUSE_SECONDS, 0.2) do
      failing(ActiveRecord::ConnectionNotEstablished.new("timeout expired"), calls: calls) do
        assert_nil store.read("hikes")
        assert_equal 2, store.fetch("hikes") { 2 }
        assert_nil store.increment("visits")
        assert_equal [:read], calls
        sleep 0.25
        assert_nil store.read("hikes")
        assert_equal %i[read read], calls
      end
    end
  end
end
