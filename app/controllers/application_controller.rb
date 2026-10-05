class ApplicationController < ActionController::Base
  around_action :first_to_providers
  after_action :count_visit

  private

  # Requests to providers that visitors wait on go ahead of background work's.
  def first_to_providers(&)
    ProviderSlots.with_priority(ProviderSlots::VISITOR, &)
  end

  # Counts the visit, without cookies; see VisitTracker. Counting never gets in the way of a page.
  def count_visit
    VisitTracker.response(request, response)
  rescue StandardError => error
    Rails.logger.warn("Visit not counted: #{error.class}")
  end
end
