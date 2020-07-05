class SearchesController < ApplicationController
  def new;end

  def show
    origin = Google::Maps.geocode(params[:origin]).first
    arrival_time = time_value(params, :arrival_time)

    return unless(origin && arrival_time)

    @trails =
      TrailsService.get_trails(origin: origin, arrival_time: arrival_time)
  end

  private

  def time_value(hash, field)
    Time.zone.local(*(1..5).map { |i| hash["#{field}(#{i}i)"] }).to_i
  end
end
