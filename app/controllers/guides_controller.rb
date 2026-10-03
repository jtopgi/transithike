# Guides to day hikes by train from big cities, which search engines and AI
# assistants can read: built weekly, so pages need no lookups.
class GuidesController < ApplicationController
  def index
    @pages = GuideService.pages
    expires_in 1.hour, public: true
  end

  def show
    @page = GuideService.page(params[:city])
    return head(:not_found) unless @page

    expires_in 1.hour, public: true
  end

  # A hike that's no longer in a guide, as routes leave when trips change, leads to its city's guide.
  def hike
    @page = GuideService.page(params[:city])
    return head(:not_found) unless @page

    @hike = @page.hike(params[:hike])
    return redirect_to(guide_path(@page.guide.slug)) unless @hike

    expires_in 1.hour, public: true
  end
end
