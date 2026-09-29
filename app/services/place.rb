# A starting point. Suggestions and the device's location already carry
# coordinates; time_zone is an IANA name such as "America/Los_Angeles".
Place = Struct.new(:name, :latitude, :longitude, :time_zone, keyword_init: true)
