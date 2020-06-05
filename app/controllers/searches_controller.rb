class SearchesController < ApplicationController
  def new
  end

  def show
    @trails = nil
    return unless params[:q]

    coordinates = Geocoder.search(params[:q]).first.coordinates
    @trails = HikingProjectService.get_trails(coordinates)
  end
end
