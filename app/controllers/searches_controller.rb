class SearchesController < ApplicationController
  include SearchOrigin

  def new
    @origin = params[:origin] if params[:origin].is_a?(String)
    @guides = GuideService.pages
  end

  # The results page shows at once, and streams hikes in as they are found.
  def show
    @origin = params[:origin] if params[:origin].is_a?(String)
    @origin = origin_text
  rescue SearchErrors::InvalidInput => error
    @error = error.message
    render :show, status: :unprocessable_content
  end
end
