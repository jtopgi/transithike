# TransitHike

[![CI](https://github.com/jtopgi/transithike/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/jtopgi/transithike/actions/workflows/ci.yml)

Find hiking routes you can reach by public transit, recommended by how good a
day hike they look and how quickly transit gets you there. The application is
Rails-rendered with Bootstrap: a starting-point box that suggests places as you
type (or uses the device's location), and a results page of route cards with map
previews, nearby photos, highlights, and popularity that can be sorted by
recommendation, travel time, distance, popularity, scenery, or length and filtered
by length and travel time.

## Requirements

- Ruby **3.4.10** and Bundler **2.6.9** (see the Ruby version and bundle lockfiles).
- Node.js **22 LTS**, Yarn **1.22.22**, and PostgreSQL **16** or newer.
- Chrome/Chromium for the browser test. Selenium manages the driver.
- Internet access for searches. No API keys or paid accounts are needed: place
  suggestions come from [Photon](https://photon.komoot.io), transit routing from
  [Transitous](https://transitous.org), routes and map tiles from OpenStreetMap,
  and photos from Wikipedia.

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

- Searches look for routes within **10 km** of the origin, widening to 20, 40, and
  **80 km** until at least **250** routes are found, so dense regions stay local
  and sparse ones reach hikes farther away. Routes spanning less than 300 m or more
  than **30 miles**, and repeated sections of one named trail (the same name within
  5 km), are left out. Results are not an exhaustive trail inventory.
- Transitous lists every stop reachable within 150 minutes. Routes within a
  30-minute walk of one, or of the origin (the most the planner walks), are checked
  for transit, most promising first (routes with Wikipedia or Wikidata entries, of
  day-hike size, with distinctive names), up to **120** per search, keeping the
  section of a trail that transit reaches soonest. Where transit is too dense to
  list every stop (over 8 MB, remembered for a day), the checks are spread over
  distance rings instead (40 within 15 km, 50 within 35 km, and 30 beyond), then
  the nearest remaining routes.
- Lengths are approximate, calculated from deduplicated mapped way geometry;
  routes under half a mile are left out. Nested or incomplete routes are skipped.
  Directions and travel times lead to the point on each route that transit reaches
  soonest, estimated from the reachable stops and a straight-line walk (or to its
  first mapped point when stops are unknown). That point is not necessarily an
  official or accessible trailhead: check the route and local conditions.
- Only routes reachable by public transit within **3 hours**, or on foot, are
  shown: the best **30**, with at most two from one park or natural area before
  the rest. Journeys may include up to 15 minutes' walk to the first stop and 30
  minutes from the last stop. The page re-sorts and filters them without another
  search.
- **Recommended** adds a point for routes of 1.5 to 12 miles (half for 1 to 1.5 miles
  or longer), up to two for highlights, about 0.75 per tenfold increase in page
  views above 100, and half a point for routes with Wikipedia or Wikidata entries.
  It subtracts 2.5 points for fully paved routes (less for partly paved ones), one
  for generic names such as "Trail 2", 0.75 per hour of travel beyond 45 minutes
  plus another point per hour beyond two hours, and 0.2 per transfer.
- **Highlights** are mapped waterfalls, summits, and viewpoints within 150 m of a
  route's ways; waterfalls and summits count twice as much as viewpoints, and
  unnamed ones half as much as named ones. The paved share comes from mapped
  surfaces, roads, and sidewalks.
- **Popularity** is Wikipedia page views over the last 30 days of the nearest park
  or natural area article to the middle of a route, not of the route itself:
  "Popular" from 300 views and "Very popular" from 2,000. Articles count as natural
  areas by their short description ("Park in Seattle"), or their title when they
  have none.
- There is no time to choose: trips leave now (rounded to the next quarter hour)
  between 5 AM and 3 PM at the origin, and otherwise at 8 AM the next morning,
  using the time zone Transitous reports for the origin (UTC when unknown).
- Photos show the lead image of the same article, within 2 km of the middle of a
  route, which is not necessarily the route. Elevation is not shown.
- Provider failures produce a friendly error, not misleading empty results. Stops,
  highlights, and popularity only refine a search, which goes ahead without them.
  Highlights not found within 5 seconds of planning trips are left out, and the
  lookup finishes in the background so later searches have them.

Route data is © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the ODbL. The public Overpass server is shared infrastructure:
follow its [usage guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
For significant traffic, arrange dedicated capacity and suitable caching rather
than relying on this public instance. When it is busy, searches use the public
[VK Maps mirror](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances)
instead, and prefer it for five minutes. Provider calls have bounded timeouts and
result limits. An area's routes are cached for **a day** for origins rounded to
about 5 km, so nearby searches share them, and each route's details and highlights
for **a week**; production uses a bounded, process-local memory store. Failures
are never cached.

Transit travel times come from [Transitous](https://transitous.org), a free,
community-run [MOTIS](https://github.com/motis-project/motis) service built on
open timetable feeds and OpenStreetMap. It needs no API key, but its
[usage policy](https://transitous.org/api/) applies: the code must stay open
source (this repository is MIT-licensed), use must be non-commercial, pages link
to its [data sources](https://transitous.org/sources/), and requests identify the
app with `SearchHttp::USER_AGENT` (change it if you fork). Contact the maintainers
in their [Matrix room](https://matrix.to/#/%23transitous:matrix.spline.de) before
sending substantial routing traffic. Each search asks for the stops reachable from
the origin with the one-to-all API, then for every checked route's trip in one
request to the experimental one-to-many API, cached for 15 minutes, and falls back
to planning the 15 nearest routes one at a time if that API fails. Transitous
serializes concurrent requests from one client, so requests are never sent in
parallel. It also supplies each origin's time zone and area name, cached for 30
days. Transit coverage depends on the feeds Transitous has for a region.

Place suggestions and typed searches use [Photon](https://photon.komoot.io),
whose public instance asks for fair use: the page waits for three characters
and a pause in typing, suggestions are cached for a day, and they favor places
near the visitor's time zone without asking for their location. Map previews
load [OpenStreetMap tiles](https://operations.osmfoundation.org/policies/tiles/)
only as cards scroll into view, and photos and page views come from the
[Wikipedia API](https://www.mediawiki.org/wiki/API:Etiquette) with each
author and license credited, cached for a week and shared by routes within about 1 km. Suggestions, photos, and
searches are rate limited per visitor. The Directions link opens Google Maps'
public directions page, which needs no API key. Provider outages cannot be
validated by offline tests; perform a real search before launching.

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
point and sort and filter the results.

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
Back up any existing database and credentials and test on staging before replacing
an old deployment. Rails defaults have changed from 6.0 to 8.1; existing browser
sessions may need to be renewed.

## Deploying to Azure

The app runs at <https://transithike.azurewebsites.net> on
[Azure App Service](https://learn.microsoft.com/azure/app-service/) and deploys
from GitHub Actions:

- After CI passes on `master`, the `deploy` job signs in to Azure with OpenID
  Connect (no stored passwords), pushes the image to Azure Container Registry
  tagged with the commit SHA, and points the web app at it. The image reports
  its commit in an `X-App-Revision` header, so the job waits until the new build
  serves traffic, loads the site twice with its session cookie, and runs one
  real search; a provider outage there only produces a warning. Deployments and
  the app URL appear under the repository's `production` environment.
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
