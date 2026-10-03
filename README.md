# TransitHike

[![CI](https://github.com/jtopgi/transithike/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/jtopgi/transithike/actions/workflows/ci.yml)

Plan weekend day hikes you can reach by train from the city, with a train back
the same evening. It is for city dwellers who want a Saturday or Sunday out of
town: hikes near commuter-rail, Amtrak, and other train stations, not the parks
the subway already reaches. The application is Rails-rendered with Bootstrap: a
starting-point box that suggests places as you type (or uses the device's
location) with a Saturday/Sunday choice, and a results page that shows at once
and streams in hikes as they are found, most scenic first. Only hikes you can
finish before the last trip back are shown. Each card has a map preview, photos
taken nearby, highlights, how far the hike goes (a loop, out and back, or one way
to where transit leaves from the far end) and climbs, the round trip's travel
time, the last trip back and how long that leaves there, and the trains and
other transit there, the first trip back after the hike, and the last. Each hike
has a details page with timetables of every trip there that leaves time to hike
it and every trip back. Hikes can also be sorted by recommendation, round trip,
time there, or length, and filtered with sliders for the longest round trip
(spanning the hikes found, from the quickest to any) and a range of lengths.
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
local socket. Use a separate database for tests. No application records or seed
data are required.

## External services and changed behavior

The previous implementation depended on the legacy Hiking Project API. This
version instead queries hiking-route relations from
[OpenStreetMap via Overpass](https://wiki.openstreetmap.org/wiki/Overpass_API).
It does not scrape Hiking Project or require its old API key.
Current Hiking Project availability could not be confirmed. Live probes of both
trail providers were blocked by DNS restrictions in the modernization environment;
test Overpass connectivity from your deployment before launching.

- **Stations.** Transitous lists the stops any transit reaches from the origin
  within an hour (40 or 25 minutes where that list is over 8 MB, remembered for a
  day per area). Trains are boarded at up to **three** of the busiest train
  stations among them, at least 1 km apart, skipping any that an earlier one's
  trains reach within 10 minutes of getting there directly; so the trip may start
  on the subway, a bus, or on foot. From each, Transitous lists the stations
  reached by commuter, regional, intercity, and suburban trains
  (`TransitousService::TRAIN_MODES`, which leave out Transitous's `RAIL`, since it
  includes the subway) within **3½ hours** of setting out, or within 120 or 80
  minutes of boarding where that list is over 8 MB, as across Switzerland
  (remembered for a day per area). Stations closer than **20 km** to the origin
  are in or next to the city and don't count.
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
  walks) are checked, most promising first (routes with Wikipedia or Wikidata
  entries, of day-hike size, with distinctive names), up to **120** per search,
  keeping the section of a trail that trains reach soonest. Results are not an
  exhaustive trail inventory; where few hiking routes are mapped in OpenStreetMap
  near stations, there are few results.
- Routes are checked in batches of 40, starting with the first tiles' while the
  others are found, and each batch's hikes show as soon as their trips there and
  back are known. A batch that fails is skipped; a search fails only when nothing
  is found.
- **Weekend trips.** Searches are for Saturday or Sunday: the one chosen, or
  whichever comes first. Trips leave at **8 AM** that day in the time zone
  Transitous reports for the origin (UTC when unknown), or now (rounded to the
  next quarter hour) once that morning has begun; from 10 AM it's too late to set
  out, so the trip is for the same day a week later. The search page offers the
  next weekend day by the device's clock. Only routes reachable within **4
  hours** of setting out, waiting included, are shown, and only with a way back
  that arrives by **11 PM** the same day and leaves time to hike **all** of the
  route at 2 mph with breaks (at least 1½ hours, to enjoy short ones) and still
  leave the last trip back half an hour to spare. Routes too long for that, such
  as 20-mile long-distance trails, are left out. Journeys may include up to 30
  minutes' walk from the last stop, and from the route to the first stop on the
  way back.
- **Loops, out and back, or one way.** Routes whose ends meet, or come within
  1 km of each other, are hiked as loops. Other routes are hiked out and back,
  twice their length, back to where transit reached them, which is the distance
  cards show and sort and filter by. When that would be over 10 miles, or leave
  too little time, and transit reaches the route within 1.5 km of an end, it can
  instead be hiked one way to the far end, if transit leaves from there late
  enough. The search asks for the last trips back from every route and every such
  far end in one request. Those cards say so, mark the finish on the map, add
  **Directions back** from it, and plan the trips back from there, preferring
  ones that ride at most a quarter longer than the trip there, plus 15 minutes.
- **There and back the same way.** Each card shows the round trip: the rides
  there and back. Until a card's trips are planned, it is twice the trip there
  (waiting for the first train included), since coming back the same way takes
  about as long; ranking, sorting, and the round-trip slider start from that.
  Once the card scrolls into view, its trips are planned: the soonest trip there,
  then the trips back that ride the same trains back between the same stations
  (via the station where the last train stopped and the one where the first
  started), with the same kinds of transit or the subway and light rail for the
  ride home. Buses often stop across the street on the way back, so a trip there
  without trains keeps only its kinds of transit. Trips back that ride more than
  a quarter longer than the trip there, plus 15 minutes, don't count, so an
  evening bus or a slow detour isn't suggested. The card shows the first trip
  home after hiking for the time the search requires, and the last such trip,
  which also sets the time there (flagged when it's less than the hike needs),
  each with its transit. Where the same way doesn't run after the hike, the
  quickest other way is shown, and the card says so.
- **Details and timetables.** Each card links to a page for its hike (left out
  of search engines, since every starting point has its own) with a map to
  explore, the hike's facts, its photos, and two timetables: every trip there
  from 8 AM on that arrives in time to hike all of it before the last trip back,
  leaving out any that ride much longer than the quickest, and every trip back
  from the first after the hike, if you take the first trip there, to the last.
  Each row has when it leaves and arrives, how long it rides, and its transit with
  the stops it rides between. The route's highlights, terrain, and photos are
  looked up while transit is planned, and the page shows without them after 10
  seconds. Its trips are looked up the way cards' are, sharing their cache.
- **Not the city's parks.** Hikes the subway, metro, or light rail
  (`TransitousService::CITY_MODES`: Transitous's `SUBWAY` and `TRAM`; its `METRO`
  means suburban trains) reach within those 4 hours are left out, since
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
  at least 300 m (about 1,000 ft), and "Views" from 150 m.
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
  Terrain is looked up for up to 100 of the most promising hikes, a few near each
  other at a time, and cached for 30 days per route; each server process keeps up
  to 200 decoded tiles (128 KB each). The footer credits the data's sources, linking
  to their [attribution](https://github.com/tilezen/joerd/blob/master/docs/attribution.md).
- **Photos** are only of nature. Each card shows up to eight in a gallery of
  thumbnails, taken within 2 km of three points along the route (its middle and
  a sixth of the way from each end), which are not necessarily of the route: the
  lead image of the nearest park or natural area's Wikipedia article, then photos
  taken along the route from Wikimedia Commons, views and waterfalls first, then
  the nearest, with at most two from a series (such as "Sugarloaf Mountain in
  summer 2" and "3"). Articles count as natural areas by the kind of thing their
  short description names first ("State park in New York" or "Range of hills in
  central England", but not "Fort on the Hudson River", "Mountain village in
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
  only refine a search, which goes ahead without them. Highlights not found within
  5 seconds of the last batch, and terrain not found within 8 seconds after that,
  are left out, and the lookups finish in the background so later searches have
  them. When the way back can't be looked up, hikes are shown with a notice saying
  so.

Route data is © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the ODbL. The public Overpass server is shared infrastructure:
follow its [usage guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
For significant traffic, arrange dedicated capacity and suitable caching rather
than relying on this public instance. Each server process sends it at most two
queries at a time, the number of slots it gives each client: other queries wait up
to 30 seconds for a slot, and highlights are skipped when none is free. When it is busy, searches use the public
[VK Maps mirror](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances)
instead, and prefer it for five minutes. When both turn a query away within 15
seconds, as they do when briefly overloaded, the preferred one is asked once more
after a 3-second pause (highlights excepted). Provider calls have bounded timeouts and
result limits. Each tile's routes are cached for **three days** and shared by every
search, and each route's details and highlights for **a week**; production uses a
bounded, process-local memory store. Failures are never cached.

Transit travel times come from [Transitous](https://transitous.org), a free,
community-run [MOTIS](https://github.com/motis-project/motis) service built on
open timetable feeds and OpenStreetMap. It needs no API key, but its
[usage policy](https://transitous.org/api/) applies: the code must stay open
source (this repository is MIT-licensed), use must be non-commercial, pages link
to its [data sources](https://transitous.org/sources/), and requests identify the
app with `SearchHttp::USER_AGENT` (change it if you fork). Contact the maintainers
in their [Matrix room](https://matrix.to/#/%23transitous:matrix.spline.de) before
sending substantial routing traffic. Each search asks for the stops reachable from
the origin with the one-to-all API (up to three times where transit is dense), and
for the stations trains reach from up to three of them, which are cached for six
hours for origins within about 100 m. Then for each batch, it asks for every
route's trip there, the trip there by city transit, and the latest trip back in
three requests to the experimental one-to-many API, all cached for 15 minutes. If
that API fails, it plans up to 15 of the nearest routes one at a time. Once a search is
done, each card the visitor scrolls to plans its trip there, then its trips back
the same way from the end of the hike until the last one in one timetable
request (and any way back in another, when the same way has none), cached the
same way. Transitous serializes concurrent requests from one
client, so a search's requests are never sent in parallel. It also supplies each
origin's time zone and area name, cached for 30 days. Transit coverage depends on
the feeds Transitous has for a region.

Place suggestions and typed searches use [Photon](https://photon.komoot.io),
whose public instance asks for fair use: the page waits for three characters
and a pause in typing, suggestions are cached for a day, and both favor places
near the visitor's time zone without asking for their location, so a ZIP code
such as 11101 finds Queens rather than a namesake abroad. Map previews
load [OpenStreetMap tiles](https://operations.osmfoundation.org/policies/tiles/)
only as cards scroll into view, and photos come from the
[Wikipedia and Wikimedia Commons APIs](https://www.mediawiki.org/wiki/API:Etiquette)
with each author and license credited, cached for a week and shared by routes within about 1 km. Suggestions, photos, trips,
and searches are rate limited per visitor. The Directions link opens Google Maps'
public directions page, which needs no API key. Provider outages cannot be
validated by offline tests; perform a real search before launching.

## Guides, search engines, and AI assistants

Search results load as they're found, which search engines and AI assistants
can't read, so the site also has **guides**: a page per city at
`/day-hikes-by-train/<city>`, and a page per hike with its route, photos,
facts, and timetables there and back, built from the same search and trip
planning, linked from the home page, the navigation, and an index of cities.

- **Cities** are listed in `config/guides.yml`, each with the point trips start
  from. Trips are for the coming Saturday, from 8 AM, back by 11 PM.
- **Weekly builds.** The [Guides workflow](.github/workflows/guides.yml) runs on
  Wednesdays (and from the Actions tab, for some cities if you like). It runs
  `bin/rails guides:build`, which searches from each city with the live
  providers (trying a city again after two minutes when a provider is busy),
  plans every hike's trips there and back with `TripPlans`, finds their photos,
  and writes `db/guides/<city>.json`. A city's guide is only
  replaced when the new one has at least 12 hikes and at least 60% as many as
  the last, so a provider's bad day doesn't empty its pages, and hikes keep their
  pages' addresses from week to week. Plain or shared names such as "White Trail"
  get the natural area nearby, or the station trains go to, in their title.
- **Publishing.** The workflow uploads the guides with `bin/publish-guides` as a
  new `guides-<time>.tar.gz` file of the `guides-data` prerelease (not to the
  repository, so its history doesn't grow every week), removing older files only
  once it's up, then runs CI on `master`, whose deploy job downloads the newest
  into the image with `bin/download-guides`. Once guides are published, a failed
  download fails the build rather than deploying, or building the next guides,
  without them. Pages read them from the image, so they need no lookups
  and load at once. To build guides locally, run
  `CITIES=new-york-city bin/rails guides:build`; `db/guides` is ignored by Git.
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
  the site and its guides for AI assistants.
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
point, sort the results and filter them with the sliders, check the first and
last trips back and a one-way hike's directions back, and browse a card's photos.
Request tests render a hike's details page and its timetables, the guides from
a sample guide, and what search engines read: link previews, structured data,
`robots.txt`, the sitemap, and `llms.txt`. Guide tests build a guide from fake
providers. Elevation tests decode generated tiles that use each of PNG's row
filters.

[GitHub Actions](.github/workflows/ci.yml) runs these checks against PostgreSQL
on every push and pull request. It also builds the production container image
and smoke-tests it without a database, including a session-cookie round trip.
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
  real Saturday search from Grand Central Terminal; a provider outage there only
  produces a warning. Deployments and
  the app URL appear under the repository's `production` environment. If GitHub
  ever skips the run for a push to `master`, run the CI workflow on `master` from
  the Actions tab ("Run workflow"), which tests and deploys it the same way.
- Images are built by GitHub Actions because Azure free-credit subscriptions
  cannot use Container Registry build tasks.
- A Linux B1 plan keeps one instance always on, so there are no cold starts.
  App Service terminates HTTPS and health-checks `/up`.

Expected cost is about **US$18/month**: roughly US$13 for the B1 plan and US$5
for the Basic registry.

### One-time setup

Install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
and [GitHub CLI](https://cli.github.com/), then run:

```sh
az login
bin/azure-setup
```

The idempotent script creates the `rg-transithike` resource group with the
registry, App Service plan and web app, and two managed identities: one pulls
images, and the other is trusted only by this repository's `production` GitHub
environment to deploy. It stores a generated `SECRET_KEY_BASE` as an app setting
and restricts that GitHub environment to the default branch. It keeps the short
`<app>.azurewebsites.net` host name, so set `AZURE_WEBAPP` if `transithike` is
taken. Credit-based subscriptions have no App Service quota in some regions; the
production plan is in `centralus` for that reason (`AZURE_WEBAPP_LOCATION`).
Push or merge to `master` to deploy.

### Operations

```sh
az webapp log tail -n transithike -g rg-transithike                       # stream logs
az webapp restart -n transithike -g rg-transithike                        # restart
az webapp config container set -n transithike -g rg-transithike \
  --container-image-name <registry>.azurecr.io/transithike:<previous-sha>  # roll back
az group delete -n rg-transithike                                         # remove everything
```

## License

[MIT](LICENSE)
