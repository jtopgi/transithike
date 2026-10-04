class ApplicationController < ActionController::Base
  after_action :count_visit

  private

  # Counts the visit, without cookies; see VisitTracker. Counting never gets in the way of a page.
  def count_visit
    VisitTracker.response(request, response)
  rescue StandardError => error
    Rails.logger.warn("Visit not counted: #{error.class}")
  end
end
