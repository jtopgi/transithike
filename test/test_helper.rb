ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Provider lookups run on thread pools, whose idle threads are shut down
  # before each test process exits: Ruby can otherwise hang for minutes
  # killing them on the way out.
  shut_down_pools = lambda do |*|
    pools = Rails.configuration.x.then { |config| [config.provider_pool, config.overpass_pool] }
    pools.each(&:shutdown)
    pools.each { |pool| pool.wait_for_termination(10) }
  end
  parallelize_teardown(&shut_down_pools)
  Minitest.after_run(&shut_down_pools)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
