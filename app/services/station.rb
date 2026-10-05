# A train station searches start from, its stop id in Transitous, which plans
# trips from it, and the stop's time zone, where Transitous gives them, or nil.
Station = Struct.new(:name, :latitude, :longitude, :id, :time_zone, keyword_init: true) do
  # Searches from the station are shared by its id, or else where it is.
  def key
    id || format("%.5f,%.5f", latitude, longitude)
  end

  def place(time_zone = nil)
    Place.new(name: name, latitude: latitude, longitude: longitude, time_zone: time_zone)
  end
end
