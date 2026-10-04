require "test_helper"

class CacheFailsafeTest < ActiveSupport::TestCase
  # The cache's database calls, failing as a database that turns the app away does.
  def turned_away
    entry = SolidCache::Entry
    originals = %i[read read_multi write write_multi lock_and_write].to_h { |name| [name, entry.method(name)] }
    originals.each_key do |name|
      entry.define_singleton_method(name) do |*, **|
        raise ActiveRecord::NoDatabaseError, 'no pg_hba.conf entry for host, database "transithike_production"'
      end
    end
    yield
  ensure
    originals&.each { |name, original| entry.define_singleton_method(name, original) }
  end

  test "the database cache misses, rather than failing, whatever the database says" do
    store = SolidCache::Store.new(namespace: "failsafe")
    turned_away do
      assert_nil store.read("hikes")
      assert_equal({}, store.read_multi("a", "b"))
      assert_not store.write("hikes", 1)
      assert_nil store.increment("visits")
      assert_equal 2, store.fetch("hikes") { 2 }
    end
    assert store.write("hikes", 3)
    assert_equal 3, store.read("hikes")
  end
end
