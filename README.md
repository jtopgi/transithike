# TransitHike

[![CI](https://github.com/jtopgi/transithike/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/jtopgi/transithike/actions/workflows/ci.yml)

Plan weekend day hikes you can reach by train from the city, with a train back
the same evening. It is for city dwellers who want a Saturday or Sunday out of
town: hikes near commuter-rail, Amtrak, and other train stations, not the parks
the subway already reaches. The application is Rails-rendered with Bootstrap: a
starting-point box that suggests places as you type (or uses the device's
location) with a Saturday/Sunday choice, and a results page that shows at once
and streams in hikes as they are found, most scenic first. Trips leave from the
major train stations near the starting point, which the page names with
directions to each: getting to the station is up to you. Only hikes with at
least three trips there that arrive in time to finish by sunset, and at least
three trips back that leave before dark, are shown. Each card has a map preview, where
the hike is (its town or city and state or region, with the country when it
isn't the starting point's), photos taken nearby, highlights, how far the hike goes (a loop, out and back, or one way
to where transit leaves from the far end) and climbs, the round trip's travel
time, the last trip back and how long that leaves there, and the trains and
other transit there and the last trip back. Each hike
has a details page with timetables of every trip there that leaves time to hike
it and every trip back until dark. Hikes are listed most scenic first, and filtered with
sliders for the longest round trip (spanning the hikes found, from the quickest
to any) and a range of lengths. On phones, the results page's search box opens
from a "Change search" button (and on its own when a search finds nothing or
fails), so the first hikes show on the first screen, the sliders share a line,
and cards are more compact.
Weekly guides list every hike from big cities, such as
[New York City](https://transithike.azurewebsites.net/day-hikes-by-train/new-york-city),
on pages that search engines and AI assistants can read.

## Requirements

- Ruby **3.4.10** and Bundler **2.6.9** (see the Ruby version and bundle lockfiles).
- Node.js **22 LTS**, Yarn **1.22.22**, and PostgreSQL **16** or newer.
- Chrome/Chromium for the browser test. Selenium manages the driver.
- Internet access for searches. No API keys or paid accounts are needed: place
  suggestions come from [Photon](https://photon.komoot.io), transit routing from
  [Transitous](https://transitous.org), routes and map tiles from OpenStreetMap,
  elevation from [Terrain Tiles on AWS](https://registry.opendata.aws/terrain-tiles/),
  traffic noise in the US from the U.S. DOT's
  [National Transportation Noise Map](https://www.bts.gov/geospatial/national-transportation-noise-map),
  and photos from Wikipedia and Wikimedia Commons.

The application uses Rails 8.1, Puma 8, Propshaft, esbuild, and Bootstrap 5.
Webpacker, jQuery, Spring, and the obsolete Google Maps Ruby wrapper are removed.

## Local setup

From the repository root, with PostgreSQL running and a local role that can
create databases:

```sh
gem install bundler -v 2.6.9
corepack enable
bundle install
bin/setup
bin/rails server
```

Open <http://localhost:3000>. `bin/setup` installs locked JavaScript dependencies,
builds assets, and prepares the database. For frontend development, run
`yarn build --watch` in a second terminal. No separate webpack server is needed.

Rails also accepts `DATABASE_URL` when PostgreSQL is not available through a
local socket. Use a separate database for tests. The tables are the cache's
(`solid_cache_entries`) and the hiking routes the guide builds collect
(`hiking_routes` and `route_tiles`), and no seed data is required.

## External services and changed behavior

The previous implementation depended on the legacy Hiking Project API. This
version instead queries hiking-route relations from
[OpenStreetMap via Overpass](https://wiki.openstreetmap.org/wiki/Overpass_API).
It does not scrape Hiking Project or require its old API key.
Current Hiking Project availability could not be confirmed. Live probes of both
trail providers were blocked by DNS restrictions in the modernization environment;
test Overpass connectivity from your deployment before launching.

- **Major stations.** Searches start from the major train stations near the
  starting point, rather than the starting point itself: people know how to get
  to their city's stations, and every search near them shares the stations'
  results. Transitous's map lists the stations of commuter, regional, intercity,
  and suburban trains (`TransitousService::TRAIN_MODES`, which leave out
  Transitous's `RAIL`, since it includes the subway) within **10 km** (or 25 or
  50 km where there are none), stops within 400 m counting as one station. The
  major ones are at least a fifth as busy as the busiest, by Transitous's
  importance, taken busiest and nearest first (busyness counts half as much 5 km
  away). Up to **six** are chosen, each adding lines the others don't: a station
  whose trains in the two hours after setting out only go across the city is
  left out, and so is one that a chosen station's trains reach within 15 minutes,
  unless at least a quarter of its trains are on other lines. From New York's
  Queens, that is Grand Central, Penn Station, and Hoboken, Harlem–125th Street
  repeating Grand Central's lines; from central Paris, its six main stations.
  A place's stations are remembered for a week for places within about 1 km.
- **Stations trains reach.** From each major station, Transitous lists the
  stations its trains reach within **4½ hours** of setting out, waiting for the
  train included, as a line's first train may leave a while after 8 AM. Where
  that list is over 8 MB, the longest of 3½ hours, 2 hours, or 80 minutes that
  fits is listed instead: 3½ hours from Paris, London, Berlin, and Munich, and
  less across Switzerland (remembered for a day per area). Stations closer than
  **20 km** to the major station are in or next to the city and don't count.
  Hikes whose trips there and back, as planned, ride more than **8 hours** in
  all aren't shown.
- **Routes.** Hiking-route relations are found in 0.5° tiles holding routes
  within a 30-minute walk of a station, up to 20 tiles: the 8 with the quickest
  stations within 2 hours, 7 within 3 hours, and 5 farther, so the scenery
  farther out is searched as well as the nearest (a band without enough tiles
  leaves room for more of the quickest). The four quickest are queried first, the
  rest four neighbors at a time, each query finding the routes of the region
  around its tiles once, then keeping those in the tiles (a tile's routes are
  left out when its query fails). Routes
  spanning less than 300 m, under **1 mile** or over **30 miles** long, at least
  half on paved paths or roads, and repeated sections of one named trail (the same
  name within 5 km) are left out: they are walks or multi-day trails rather than
  day hikes. Routes within a 30-minute walk of a station (the most the planner
  walks) are checked, most promising first, up to **120** per search, keeping
  the section of a trail that trains reach soonest. Promise counts much as the
  ranking does: routes with Wikipedia or Wikidata entries, of day-hike size,
  with distinctive names, across land that rises more (up to 400 m, from coarse
  zoom-8 terrain tiles about 100 km across, sampled on a 5-by-5 grid over each
  route's bounding box), and without long trips there. Up to 40 of the 120,
  counting those the first batch checked, are routes 3 hours or more away,
  however promising nearer ones are: otherwise the trip there kept them from
  being checked, and from Grand Central no hike found rode over 5 hours there
  and back. Without the land, an area where most routes
  have Wikidata entries, such as Franconia's, took most checks from Munich, and
  the Alps few. Results are not an exhaustive trail inventory; where few hiking
  routes are mapped in OpenStreetMap near stations, there are few results.
- Routes are checked in batches of 40, starting with the first tiles' while the
  others are found, and each batch's hikes show as soon as their trips there and
  back are known. Routes that can't be looked up at once, as when Overpass is
  busy, are looked up again after a pause: a batch none of whose routes could be
  in halves, and a half that still can't be is skipped, or else the batch, with
  those found already read again from the cache or database, and any still
  missing left out. A search fails only when nothing is found.
- **Shared searches.** Each major station's search runs in the background, at
  most three at once per server process for searches visitors wait on and one
  more searching again in the background, and is shared by every search that
  starts there at the same time, so everyone near Grand Central waits on the same
  one. It finishes, and is kept in the database for 8 days, even when the visitor
  who started it leaves. Kept searches show at once, and once 12 hours old (10
  minutes when some routes couldn't be checked), the station is searched again
  in the background for later visitors, keeping routes an earlier search found
  that the new one couldn't check, unless found too loud since; kept searches
  show without hikes that aren't shown now. Where a station hasn't been searched for the day yet, its search for
  the same weekday and time from up to two weeks before shows at once, moved to
  the day, while the day is searched in the background: timetables rarely change
  from one week to the next, and each card plans its trips for the day. Searches
  no visitor waits on, searching again and keeping searches ready, run one at a
  time on threads of their own, so a visitor's search isn't queued behind them,
  and their requests to Overpass and Transitous wait behind those of visitors
  and of searches visitors wait on, until a visitor waits on them too.
  Background searches wait while two others are queued, and a station isn't
  searched again within 10 minutes of the last try. A hike that several
  stations reach shows from the one that gets there soonest, counting
  the trip across the city to each station at about 15 km/h, and a card is
  replaced when a station that gets there sooner finds it. While nothing new is
  found, the stream sends a comment every 15 seconds to keep the connection open.
- **Ready ahead.** With `WARM_SEARCHES=1`, the web server searches the major
  stations of each guide city in the US that has a guide, where most visitors
  are, for the next Saturday and Sunday once a day, one at a time and starting 2
  minutes after it boots, unless their kept searches are recent and complete,
  so the first visitor near them doesn't wait. These run in the background,
  behind searches visitors wait on.
- **Weekend trips.** Searches are for Saturday or Sunday: the one chosen, or
  whichever comes first. Trips leave at **8 AM** that day in the time zone
  Transitous reports for the origin (UTC when unknown), or now (rounded to the
  next quarter hour) once that morning has begun; from 10 AM it's too late to set
  out, so the trip is for the same day a week later. The search page offers the
  next weekend day by the device's clock. Only routes reachable within **5
  hours** of leaving the station, waiting included, are shown, and only with a way
  back to it that arrives by **11 PM** the same day and leaves time to hike **all** of the
  route at 2 mph with breaks (at least 1½ hours, to enjoy short ones) by sunset,
  and still leave the last trip back half an hour to spare. That last trip back
  leaves before dark, so no one waits for it in the dark. Sunset and dark (the
  end of civil twilight, with the sun 6° below the horizon) are worked out for
  the route and day with the sunrise equation, to within a minute or two; the
  twilight between them leaves light for the walk to the station. So missing a
  train isn't a worry, a hike needs at least **three** trips there that arrive in
  time and three back that leave before dark: once its quick checks pass, each
  hike's trips are planned, three hikes at a time, and it shows as soon as they
  are. Routes too long for that, such as 20-mile long-distance trails, short
  winter days, and lines with few trains, are left out. Journeys may include up to 30
  minutes' walk from the last stop, and from the route to the first stop on the
  way back.
- **Loops, out and back, or one way.** Routes whose ends meet, or come within
  1 km of each other, are hiked as loops. Other routes are hiked out and back,
  twice their length, back to where transit reached them, which is the distance
  cards show and filter by. When that would be over 10 miles, or leave
  too little time, and transit reaches the route within 1.5 km of an end, it can
  instead be hiked one way to the far end, if transit leaves from there late
  enough. The search asks for the last trips back from every route and every such
  far end in one request. Those cards say so, mark the finish on the map, add
  **Directions back** from it, and plan the trips back from there, preferring
  ones that ride at most a quarter longer than the trip there, plus 15 minutes.
- **There and back the same way.** Each card shows the round trip: the rides
  there and back. Until a card's trips are planned, it is twice the trip there
  (waiting for the first train included), since coming back the same way takes
  about as long, but at most 8 hours, as no hike shown rides longer; ranking and
  the round-trip slider start from that.
  Once the card scrolls into view, its trips are planned by train, with the
  subway or light rail to reach the trains, and a walk of up to 30 minutes at
  either end; buses and coaches only where no such trip goes, such as back from
  the far end of some one-way hikes. When choosing between trips, each ride
  counts 10 minutes longer, so trips walk rather than ride only a few minutes
  sooner, and a ride at either end that a walk of up to 20 minutes replaces,
  arriving at most 10 minutes later, is walked, as a short bus home from the
  station is. The planner also looks to other days when nothing goes, so trips
  outside the day asked for are left out. The soonest trip there leaves as late
  as still arrives that soon (from the planner's trips until the last that
  arrives in time, since an earlier train often just waits at a transfer for
  the one a later train makes), and the trips back ride the same trains back between the same stations
  (via the station where the last train stopped and the one where the first
  started), with the same kinds of transit or the subway and light rail for the
  ride home. Buses often stop across the street on the way back, so a trip there
  without trains keeps only its kinds of transit. Trips back that ride more than
  a quarter longer than the trip there, plus 15 minutes, don't count, so an
  evening bus or a slow detour isn't suggested. The card shows the soonest trip
  there and the last trip back before dark, each with its transit, and the time
  there until it. A hike whose planned trips have since changed, and leave too
  little time or too few trips, is taken off the page. Where the same way
  doesn't run after the hike, before dark, the quickest other way is shown, and
  the card says so.
- **Details and timetables.** Each card links to a page for its hike (left out
  of search engines, since every starting point has its own) with a map to
  explore, the hike's facts, its photos, and two timetables from its station, and
  back to it: every trip there
  from 8 AM on that arrives in time to hike all of it by sunset and before the last trip back,
  leaving out any that ride much longer than the quickest, and every trip back
  from the first after the hike, if you take the first trip there, to the last
  one before dark. When no trip there arrives in time, the page says so.
  Each row has when it leaves and arrives, how long it rides, and its transit with
  the stops it rides between. The route's highlights, terrain, and photos are
  looked up while transit is planned, and the page shows without them after 10
  seconds. Its trips are looked up the way cards' are, sharing their cache, and
  it links back to the search from the starting point.
- **Not the city's parks.** Hikes the subway, metro, or light rail
  (`TransitousService::CITY_MODES`: Transitous's `SUBWAY` and `TRAM`; its `METRO`
  means suburban trains) reach within those 5 hours are left out, since
  city dwellers likely know them already; when that can't be checked, they stay.
- Lengths are approximate, calculated from deduplicated mapped way geometry.
  Nested or incomplete routes are skipped. Directions and travel times lead to the
  point on each route that trains reach soonest, estimated from the stations and a
  straight-line walk. That point is not necessarily an official or accessible
  trailhead: check the route and local conditions.
- **Most scenic**, the default order, scores a hike's best feature in full, the
  next best half, and the third a quarter, so one grand view outranks many small
  ones. Its views score a point for every 100 m it climbs or its high point stands
  above the land around it, whichever is more, up to four, plus half a point for
  a mapped viewpoint, a quarter for a named summit, and one for a summit or
  viewpoint with a Wikipedia article. Each waterfall scores 1.5, plus half a point
  for a name, one for a Wikipedia article, and one for every 20 m of mapped height,
  up to 1.5. Cards show "Big views" when the higher of the climb and the relief is
  at least 300 m (about 1,000 ft), and "Views" from 150 m. Scenery only ranks
  hikes: flat ones are shown too, after the more scenic. In the 48 contiguous
  states, quiet surroundings score up to two points more, about as much as a good
  view: a point's quietness is 1 under 45 dB, two thirds from 45, a third from 50,
  and none from 55 dB, averaged over up to 64 points along the route. Cards show
  "Quiet" from 0.85. Elsewhere, and where the noise isn't found in time, it
  adds nothing, so hikes outside the US keep their order.
- **Traffic noise** in the 48 contiguous states comes from the U.S. DOT Bureau
  of Transportation Statistics'
  [National Transportation Noise Map](https://www.bts.gov/geospatial/national-transportation-noise-map):
  road, rail, and aviation noise, modeled for 2022 as the average sound level over
  a day, in public map tiles with no key. Zoom-12 tiles, about 7 km across with a
  level about every 30 m, are fetched as palette PNG images and decoded in Ruby,
  each color standing for the band of decibels the map's legend gives it. Only
  hikes under 45 dB along most of the way are shown, away from busy
  roads, highways, railways, and flight paths. Cards and hike pages show the
  level along at least half of a route as the legend's band, such as "< 45 dB",
  and a louder one in places when at least a twentieth of it reaches one, so
  crossing a road doesn't count. Each batch's noise is looked up while its
  transit is checked, near routes together, waiting at most 8 seconds, and
  cached for 90 days per route; each server process keeps up to 200 decoded
  tiles (64 KB each). Searches use it from stations in the contiguous states'
  time zones, as Transitous gives each stop's, so a station's search is the same
  whoever starts it, and hike pages for routes in them, from Transitous's
  reverse geocoding. The map shows nothing beyond the border, so a route across
  it, rarely a day trip by train from the US, would count as quiet.
- **Recommended** adds 1.5 points for hikes of 3 to 12 miles (1 for 2 to 3 or 12
  to 16 miles, a quarter for shorter ones), counting out and back twice, 0.6 per
  point of scenery, and half a point for routes with Wikipedia or Wikidata
  entries. It subtracts up to 1.25 points for partly paved routes, one for generic
  names such as "Trail 2", a quarter point per hour of round trip beyond three
  hours plus another half point per hour beyond six hours, 0.1 per transfer, and
  1.5 points for a route within 3 km of two that rank higher, for variety.
- **Highlights** are mapped waterfalls, summits, and viewpoints within 150 m of a
  route's ways, waterfalls first, and famous ones (with a Wikipedia article) and
  named ones before the others. The paved share comes from mapped surfaces,
  roads, and sidewalks.
- **Terrain** comes from [Terrain Tiles on AWS](https://registry.opendata.aws/terrain-tiles/):
  open elevation data (USGS 3DEP in the US, and SRTM, GMTED2010, EU-DEM, and
  others elsewhere) in map tiles, free, with no key or rate limit. Zoom-11 tiles,
  about 15 km across with a height about every 60 m, are fetched as PNG images and
  decoded in Ruby. A hike's climb runs from the lowest to the highest of up to 64
  points along it, and its relief is how far that high point stands above the
  lowest of 16 points 1 and 2 km around it. Heights below sea level count as sea
  level, since the tiles hold river and sea beds and a few gaps in the data there.
  Terrain is looked up for each batch's routes while their transit is checked,
  waiting at most 8 seconds, and again at the end for up to 100 of the most
  promising hikes still without it, a few near each other at a time, and cached
  for 30 days per route; each server process keeps up to 200 decoded tiles (128
  KB each). The footer credits the data's sources, linking
  to their [attribution](https://github.com/tilezen/joerd/blob/master/docs/attribution.md).
- **Photos** are only of nature. Each card shows up to eight in a gallery of
  thumbnails, taken within 2 km of three points along the route (its middle and
  a sixth of the way from each end), which are not necessarily of the route: the
  lead image of the nearest park or natural area's Wikipedia article within 5 km
  (big parks' articles are placed at their middle), then photos taken along the
  route from Wikimedia Commons, views and waterfalls first, then the nearest, with
  at most two from a series (such as "Sugarloaf Mountain in summer 2" and "3").
  Commons is asked for the type and size of 200 files near each point, then for
  the credits and categories of the nearest 50 that could be photos of the
  scenery, following its answers until every category is in, since near towns the
  nearest files are mostly of streets and buildings. Commons gets up to 20 seconds
  to answer and Wikipedia 10, but a route's lookups stop after 15 seconds
  altogether (60 in guide builds), keeping what's found by then, so a slow Commons
  doesn't hold up the server, and cards load their photos two at a time. A lookup
  that fails only leaves out its own photos, and guide builds try a failed lookup
  once more after 10 seconds. Articles count as
  natural areas by the kind of thing their short description names first ("State
  park in New York" or "Range of hills in central England", but not "Fort on the
  Hudson River", "Garden House in Dormansland, Surrey", "Mountain village in
  Switzerland", or "Series of chains across the Hudson River"), or by their title
  when they have none. Photos are JPEGs at least 800 px wide and at most three
  times wider than tall, whose title or a visible Commons category names a
  natural feature (a mountain, ridge, lake, river, waterfall, forest, trail,
  preserve, and so on), and neither names anything built, vehicles, people,
  close-ups of wildlife (including species' scientific names), maps, or artworks
  ("Alexander Hamilton by Franklin Simmons"). Places named like nature, such as
  "Cold Spring, New York", "Long Island", or a place in parentheses, don't count.
  Some hikes have no photos of nature nearby, and then show only the map. Credits
  leave out the names Commons repeats in hidden elements.
- Provider failures produce a friendly error, not misleading empty results. The
  origin's area, the tiles after the first four, highlights, terrain, and photos
  only refine a search, which goes ahead without them; when any tile's routes
  don't load, the page says some hikes couldn't be checked, and guide builds try
  that city again. Each batch's terrain is looked up while its transit is
  checked, so cards show their climb and rank by their views as they come.
  Highlights not found within 5 seconds of the last batch (a minute for searches
  in the background, such as guide builds'), and terrain not found within 8
  seconds after that, are left out, and the lookups finish in the background so
  later searches have them. When the way back can't be looked up,
  hikes are shown with a notice saying so.

Route data is © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the ODbL. The public Overpass server is shared infrastructure:
follow its [usage guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
For significant traffic, arrange dedicated capacity and suitable caching rather
than relying on this public instance. Each server process sends it at most two
queries at a time, the number of slots it gives each client: other queries wait up
to 30 seconds for a slot, the most urgent first, as for Transitous below, and
highlights are skipped when none is free, unless no visitor waits on them. When it is busy, searches use the public
[VK Maps mirror](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances)
instead, and prefer it for five minutes. When both turn a query away within 15
seconds, as they do when briefly overloaded, the preferred one is asked once more
after a 3-second pause (highlights a visitor waits on excepted). Provider calls have bounded timeouts and
result limits. Searches keep their own copy of each tile's routes in the
database for **90 days**, shared by every search, and once a tile's copy is 30
days old, look it up again in the background while searches go on using it, so
they rarely wait for Overpass. Each route's details and highlights are kept for
**two months**. Searches that need the same tiles or routes at once share one
query, waiting up to 90 seconds for another search's. Failures are never kept.

Transit travel times come from [Transitous](https://transitous.org), a free,
community-run [MOTIS](https://github.com/motis-project/motis) service built on
open timetable feeds and OpenStreetMap. It needs no API key, but its
[usage policy](https://transitous.org/api/) applies: the code must stay open
source (this repository is MIT-licensed), use must be non-commercial, pages link
to its [data sources](https://transitous.org/sources/), and requests identify the
app with `SearchHttp::USER_AGENT` (change it if you fork). Contact the maintainers
in their [Matrix room](https://matrix.to/#/%23transitous:matrix.spline.de) before
sending substantial routing traffic. Each search asks for the train stations near
the starting point with the map stops API, and for the trains leaving each
candidate station with the stop times API, both cached for a week. Then for each
major station it asks for the stations its trains reach with the one-to-all API
(up to three times where trains are dense), cached for six hours, and for each
batch, for every route's trip there, the trip there by city transit, and the
latest trip back in three requests to the experimental one-to-many API. Trips
follow timetables that hardly change until the day, so trips more than 12 hours
ahead are cached until 12 hours before they leave, for at most a day, longer
than a kept search goes before the station is searched again, so cards show the
trips their search planned at once, and the day's for 15 minutes. If that API fails,
it plans up to 15 of the nearest routes one at a time. Once a search is
done, each card the visitor scrolls to plans its trip there, then its trips back
the same way from the end of the hike until the last one in one timetable
request (and any way back in another, when the same way has none), cached the
same way. Transitous answers at most three requests at once from one client
and turns away more, so each server process sends it at most three at once, and
others wait up to 30 seconds for a turn, the most urgent first: those a
visitor's own request makes, such as a card's trips or a hike's page, then those
of searches visitors wait on, and last those of searches in the background (see
`ProviderSlots`). For 5 minutes after a visitor's or a waited-on search's last
request, background searches leave one of the three free, as Transitous takes
several seconds to answer a busy client, and a visitor's request shouldn't wait
behind theirs. It also supplies each
origin's time zone and area name, cached for 30 days. Transit coverage depends on
the feeds Transitous has for a region.

Place suggestions and typed searches use [Photon](https://photon.komoot.io),
whose public instance asks for fair use: the page waits for three characters
and a pause in typing, suggestions are cached for a day, and both favor places
near the visitor's time zone without asking for their location, so a ZIP code
such as 11101 finds Queens rather than a namesake abroad. Photon's reverse
lookup also names where each hike is, from where transit reaches it, when its
card's trips are planned, its details page loads, or its guide is built; places
about a kilometer apart share a lookup, cached for 30 days. In Great Britain,
the county stands in for England, Scotland, Wales, or Northern Ireland. Map previews
load [OpenStreetMap tiles](https://operations.osmfoundation.org/policies/tiles/)
only as cards scroll into view, and photos come from the
[Wikipedia and Wikimedia Commons APIs](https://www.mediawiki.org/wiki/API:Etiquette)
with each author and license credited, cached for a week and shared by routes within about 1 km. Suggestions, photos, trips,
and searches are rate limited per visitor. The Directions links open Google Maps'
public directions page, which needs no API key: to each station from the starting
point, and to each hike from its station. Provider outages cannot be
validated by offline tests; perform a real search before launching.

## Guides, search engines, and AI assistants

Search results load as they're found, which search engines and AI assistants
can't read, so the site also has **guides**: a page per city at
`/day-hikes-by-train/<city>`, and a page per hike with its route, photos,
facts, and timetables there and back, built from the same search and trip
planning, linked from the home page, the navigation, and an index of cities.

- **Cities** are listed in `config/guides.yml`, each with the point trips start
  from: New York City, Boston, and Chicago in the US, and London, Zurich, Berlin,
  Paris, Munich, and Vienna in Europe. Trips are for the coming Saturday, from 8 AM, back by 11 PM.
- **Weekly builds.** The [Guides workflow](.github/workflows/guides.yml) runs on
  Wednesdays (and from the Actions tab, for some cities if you like). It builds
  each city in a job of its own, two at a time so the free providers aren't
  asked too much at once, with `CITIES=<city> bin/rails guides:build`, which
  searches from the city with the live providers
  (trying a city again after two minutes when a provider is busy or some of its
  hikes couldn't be checked, as when the farther tiles' routes don't load, and
  keeping a complete build, or else the one with more hikes), plans every hike's
  trips there and back with `TripPlans`, finds their photos and where they are,
  and writes `db/guides/<city>.json`. A city's guide is only
  replaced when the new one has at least 3 hikes and at least 60% as many as
  the last one still shows under the current rules, so a provider's bad day
  doesn't empty its pages, and hikes keep their
  pages' addresses from week to week. Plain or shared names such as "White Trail"
  get the natural area nearby, or the station trains go to, in their title.
  Guides keep each hike's sunset, and a city's page leads with its sunset among
  its facts. Guides built before these rules are held to them as they're read:
  their sunsets are worked out, trips back after dark are left out, and so are
  hikes without the daylight, or without three trips there and three back.
- **Publishing.** Once every city's job is done, the workflow adds the guides
  they built to the published ones, keeping a city's published guide when its
  job fails, and uploads them with `bin/publish-guides` as a
  new `guides-<time>.tar.gz` file of the `guides-data` prerelease (not to the
  repository, so its history doesn't grow every week), removing older files only
  once it's up, then runs CI on `master`, whose deploy job downloads the newest
  into the image with `bin/download-guides`. Once guides are published, a failed
  download fails the build rather than deploying, or building the next guides,
  without them. Pages read them from the image, so they need no lookups
  and load at once. To build guides locally, run
  `CITIES=new-york-city bin/rails guides:build`; `db/guides` is ignored by Git.
- **Hiking route database.** Overpass doesn't answer the Azure server, and
  hiking routes hardly change, so the weekly builds, which run where it does,
  also record what they look up of each route and map tile (`RouteData`): every
  tile's routes, each route's details, highlights, terrain, and traffic noise.
  The workflow publishes them as one `routes-<time>.ndjson.gz` file of the
  public `routes-data` prerelease (`bin/publish-routes`), and with
  `IMPORT_ROUTES=1` the web server imports the newest into the `hiking_routes`
  and `route_tiles` tables a minute after it boots and every 6 hours, without a
  deploy. Searches, hike pages, and their lookups read these tables wherever
  their cache has nothing (`RouteStore`), so near the guide cities they seldom
  wait on Overpass, and only ask it about routes and places the builds haven't
  looked up, as a search on another day may pick. Routes it can't look up are
  left out, while the rest of their batch is kept. A database that can't be
  reached is left alone for 30 seconds, as the cache does. Each import replaces
  what was stored of each route and tile it has, so routes are refreshed every
  week. Builds don't read the database, and publish the route data after the
  guides, so the guides go live whatever happens to it.
- **What search engines read.** Every page has a description, a canonical
  address, and link previews (Open Graph and Twitter tags, with the hike's first
  photo or `public/og-image.png`). Guides have structured data (an `ItemList` of
  hikes, `TouristAttraction`s with coordinates, and breadcrumbs), and the home
  page describes the app as a free `WebApplication`. `robots.txt` lets crawlers
  read every page but not the lookups pages make (`/search/stream`, `/trip`,
  `/photos`, `/places`, `/hike`), which would plan trips with the free providers
  for them. Search results and hike details from a search are `noindex`, since
  every starting point has its own. `sitemap.xml` lists the home page, the guides,
  and every hike's page, with when each guide was built, and `llms.txt` sums up
  the site and its guides for AI assistants, and asks them to give people a link
  to the guide, hike, or search they used, since trains change week to week.
- **IndexNow.** After a deploy that the Guides workflow starts, CI submits the
  sitemap's pages to [IndexNow](https://www.indexnow.org), which tells Bing
  (whose index ChatGPT search, Copilot, and DuckDuckGo use), Yandex, and others
  about them. Its key is public, served from `public/<key>.txt`.
- **Search consoles.** To see how Google and Bing index the site, add it to
  [Google Search Console](https://search.google.com/search-console) as a URL
  prefix and to [Bing Webmaster Tools](https://www.bing.com/webmasters), choose
  the HTML tag method, and set the tag's content as the App Service settings
  `GOOGLE_SITE_VERIFICATION` and `BING_SITE_VERIFICATION`; then submit
  `/sitemap.xml` in each. Bing can also import the site from Google's console.

## Tests and security checks

```sh
RAILS_ENV=test bin/rails db:prepare
bin/rails zeitwerk:check
bin/rails test
bin/rails test:system
bundle exec brakeman --no-pager
bundle exec bundler-audit check --update
yarn audit
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile
```

Service, request, and browser tests use deterministic provider doubles, so no
API traffic is required apart from the browser tests' map tiles. Tests cover
input validation, departure times and time zones, route filtering, sorting,
empty results, malformed responses, fallbacks, and upstream failures. Request
tests also check that the form sends the parameters the search reads and that
pages still render when a browser returns its session cookie with forgery
protection on, as in production. The browser tests choose a suggested starting
point, check the results come most scenic first, filter them with the sliders, check the first and
last trips back and a one-way hike's directions back, and browse a card's photos.
Request tests render a hike's details page and its timetables, the guides from
a sample guide, and what search engines read: link previews, structured data,
`robots.txt`, the sitemap, and `llms.txt`. Guide tests build a guide from fake
providers. Elevation and noise tests decode generated tiles that use each of
PNG's row filters.

[GitHub Actions](.github/workflows/ci.yml) runs these checks against PostgreSQL
on every push and pull request. It also builds the production container image
and smoke-tests it with a database, which it prepares as it starts, including a
session-cookie round trip and the cache, and then with an empty database that
has no cache table, when the site still serves, rate-limited pages still answer,
and the cache only misses.
Dependabot checks Ruby,
JavaScript, and GitHub Actions dependencies weekly. Commit both lockfiles when
updating dependencies.

## Production deployment

The `Dockerfile` performs steps 1–2 and runs Puma as a non-root user with
`RAILS_SERVE_STATIC_FILES` and `RAILS_LOG_TO_STDOUT` set. To deploy elsewhere:

1. Install the pinned Ruby/Node toolchains and locked dependencies:
   `bundle install` and `yarn install --frozen-lockfile`.
   esbuild is a development dependency but must be installed in the build stage.
2. Compile assets using
   `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`.
   Do **not** set `SECRET_KEY_BASE_DUMMY` in the running server.
3. Supply `RAILS_ENV=production` and a stable securely generated
   `SECRET_KEY_BASE` through the host's secret manager. The app has no database
   tables, so it runs without PostgreSQL; if you add models, also supply
   `DATABASE_URL` and run `bin/rails db:prepare` before starting the server.
4. Run `bundle exec puma -C config/puma.rb`.
5. Terminate HTTPS at a trusted proxy and forward the original protocol correctly.
   Production enforces HTTPS except for the `/up` health check. Set
   `RAILS_SERVE_STATIC_FILES=1` when Rails, rather than the proxy, should serve
   precompiled assets, and `RAILS_LOG_TO_STDOUT=1` for container logs.

Set request/concurrency limits at the proxy and monitoring before public launch. Allow sufficient upstream request time for route searches.
Results stream from `/search/stream` as Server-Sent Events, each search holding one
Puma thread until it is done (usually 2 to 40 seconds): proxies must pass the
stream through without buffering or compressing it, which the response's
`Cache-Control: no-cache, no-transform` and `X-Accel-Buffering: no` headers ask for.
Back up any existing database and credentials and test on staging before replacing
an old deployment. Rails defaults have changed from 6.0 to 8.1; existing browser
sessions may need to be renewed.

## Deploying to Azure

The app runs at <https://transithike.azurewebsites.net> on
[Azure App Service](https://learn.microsoft.com/azure/app-service/) and deploys
from GitHub Actions:

- After CI passes on `master`, the `deploy` job signs in to Azure with OpenID
  Connect (no stored passwords), downloads the latest guides, pushes the image to
  Azure Container Registry tagged with the commit SHA and the run (a commit is
  built again with new guides), and points the web app at it. The image reports
  its commit in an `X-App-Revision` header and its build in `X-App-Build`, so the
  job waits until the new build serves traffic, loads the site twice with its
  session cookie, and runs one
  real Saturday search from Grand Central Terminal for up to 4 minutes. It fails
  when the stream breaks off or finishes without hikes; a provider outage only
  produces a warning, and hikes still streaming in at 4 minutes pass, since
  nothing is cached after a deploy. Deployments and
  the app URL appear under the repository's `production` environment. If GitHub
  ever skips the run for a push to `master`, run the CI workflow on `master` from
  the Actions tab ("Run workflow"), which tests and deploys it the same way.
- Images are built by GitHub Actions because Azure free-credit subscriptions
  cannot use Container Registry build tasks.
- A Linux B1 plan keeps one instance always on, so there are no cold starts.
  App Service terminates HTTPS and health-checks `/up`.
- The cache lives in an
  [Azure Database for PostgreSQL flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/)
  (Burstable B1ms, 32 GB, 7 days of backups), through
  [Solid Cache](https://github.com/rails/solid_cache), so the hiking routes and
  searches it keeps outlive deploys; it holds up to 8 GB, each entry for at most
  120 days. The image's entrypoint creates the database and runs migrations
  before the server starts, trying three times (production never loads
  `db/schema.rb`, whose `enable_extension "plpgsql"` Azure turns away, and CI's
  database turns extensions away too), and starts the server even when
  the database can't be reached: any database error is then a cache miss, a
  database that doesn't answer within 5 seconds is left alone for 30, and rate
  limits are counted in the process, not the database. Only the web app's outbound addresses
  can reach the database, and `DATABASE_URL`, with its password, is only in the
  web app's settings.

Expected cost is about **US$34/month**: roughly US$13 for the B1 plan, US$5
for the Basic registry, and US$16 for the database.

### One-time setup

Install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
and [GitHub CLI](https://cli.github.com/), then run:

```sh
az login
bin/azure-setup
```

The idempotent script creates the `rg-transithike` resource group with the
registry, App Service plan and web app, two managed identities (one pulls
images, and the other is trusted only by this repository's `production` GitHub
environment to deploy), the Application Insights resource that counts
visits, with its Log Analytics workspace, and the PostgreSQL server with its
firewall rules. It stores a generated `SECRET_KEY_BASE`, the database's
`DATABASE_URL` with a generated password, `WARM_SEARCHES=1`, and
`IMPORT_ROUTES=1` as app settings and restricts that GitHub environment to the
default branch. It keeps the short `<app>.azurewebsites.net` host name, so set
`AZURE_WEBAPP` if `transithike` is taken. Credit-based subscriptions have no App
Service quota in some regions; the production plan is in `centralus` for that
reason (`AZURE_WEBAPP_LOCATION`). Push or merge to `master` to deploy.

### Operations

```sh
az webapp log tail -n transithike -g rg-transithike                       # stream logs
az webapp restart -n transithike -g rg-transithike                        # restart
az acr repository show-tags -n <registry> --repository transithike \
  --orderby time_desc --top 5 -o tsv                                      # recent builds
az webapp config container set -n transithike -g rg-transithike \
  --container-image-name <registry>.azurecr.io/transithike:<previous-tag>  # roll back
az group delete -n rg-transithike                                         # remove everything
```

Image tags are `<commit>-<run>-<attempt>`, one for each deployment, because the
same commit is deployed again whenever the guides are rebuilt. Builds from
before then are tagged with just the commit.

## Visits

TransitHike counts visits in [Application Insights](https://learn.microsoft.com/azure/azure-monitor/app/app-insights-overview)
from the server, with no cookies or anything else kept in visitors' browsers
(`VisitTracker`), so it needs no consent banner. After each response, a
background thread sends:

- a **page view** for each page a person sees: its path without the query
  string (so no typed addresses), the site they came from (its host name only),
  their kind of device, browser, system, and language, and their country and
  city, which Application Insights works out from the IP address and keeps
  instead of it;
- a **search** for each finished search: the area it starts from, as
  "Seattle, Washington, United States", the day, how many hikes it found, and
  how long it took;
- a **crawler visit** for each request from a search engine, AI assistant, or
  other bot, named by its user agent (Google, Bing, ChatGPT, Claude,
  Perplexity, and so on), with the path, so you can see which pages they read.

Visitors are told apart for a day by a hash of their IP address and browser
with a random salt that is replaced daily and only kept in memory, so the same
person can't be followed from one day to the next: a visitor counts once a day,
and a restart starts a new salt. Prefetches and Azure's own checks aren't
counted. Nothing is counted without the `APPLICATIONINSIGHTS_CONNECTION_STRING`
app setting, as in development and tests.

To see the numbers, run `bin/stats` (or `bin/stats 7` for a week) after
`az login`, for visitors and page views by day, the most-seen pages, the sites
people come from, countries and cities, devices, where searches start, and
crawlers' visits. The Azure portal shows the same under the `appi-transithike`
resource: **Usage → Users** and **Events**, or **Logs** for queries such as
`pageViews | summarize dcount(user_Id) by bin(timestamp, 1d)`. Data is kept for
90 days, and ingestion is capped at 100 MB a day, well within the free 5 GB a
month.

## License

[MIT](LICENSE)
