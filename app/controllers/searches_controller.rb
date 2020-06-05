class SearchesController < ApplicationController
  def new;end

  def show
    return unless params[:location]

    coordinates = Geocoder.search(params[:location]).first.coordinates
    @trails = HikingProjectService.get_trails(coordinates)
  end
end
