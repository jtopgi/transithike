# When the sun sets, from where and when, by the sunrise equation
# (https://en.wikipedia.org/wiki/Sunrise_equation), to within a minute or two
# away from the poles. Hikes are planned to end by then.
module Daylight
  J2000 = 2_451_545.0
  UNIX_EPOCH_JULIAN = 2_440_587.5
  # The sun's top edge touches the horizon 0.833° below the center, for refraction.
  SET_ALTITUDE = -0.833
  EARTH_TILT = 23.4397

  # The sunset, as a UTC Time to the minute before, on the local day of time at
  # [latitude, longitude]: nil where the sun doesn't set that day, and where it
  # doesn't rise, the start of the day, as there's no daylight.
  def self.sunset(time, latitude, longitude)
    # The local day, by the sun's time there, which a minute or two either way doesn't change.
    day = (time.utc + longitude / 15.0 * 3600).to_date
    mean_day = day.jd - J2000 - longitude / 360.0
    anomaly = (357.5291 + 0.98560028 * mean_day) % 360
    center = 1.9148 * sine(anomaly) + 0.02 * sine(2 * anomaly) + 0.0003 * sine(3 * anomaly)
    ecliptic = (anomaly + center + 180 + 102.9372) % 360
    transit = J2000 + mean_day + 0.0053 * sine(anomaly) - 0.0069 * sine(2 * ecliptic)
    declination = Math.asin(sine(ecliptic) * sine(EARTH_TILT))
    hour_angle = (sine(SET_ALTITUDE) - sine(latitude) * Math.sin(declination)) /
      (Math.cos(radians(latitude)) * Math.cos(declination))
    return if hour_angle < -1
    return Time.utc(day.year, day.month, day.day) - (longitude / 15.0 * 3600).round if hour_angle > 1

    julian = transit + Math.acos(hour_angle) * 180 / Math::PI / 360
    Time.at(((julian - UNIX_EPOCH_JULIAN) * 1440).floor * 60).utc
  end

  def self.sine(degrees)
    Math.sin(radians(degrees))
  end

  def self.radians(degrees)
    degrees * Math::PI / 180
  end
end
