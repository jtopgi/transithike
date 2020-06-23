class SearchesController < ApplicationController
  def new;end

  def show
    return unless params[:location]

    arrival_time = time_value(params, :datetime)

    @trails = TrailsService.get_trails(location: params[:location], arrival_time: arrival_time)
  end

  private

  def time_value(hash, field)
    Time.zone.local(*(1..5).map { |i| hash["#{field}(#{i}i)"] }).to_i
  end
end
