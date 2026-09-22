# TransitHike

Find nearby hiking routes reachable by public transit, ordered by estimated
travel time. The application is Rails-rendered and retains its original simple
search form and results cards.

## Requirements

- Ruby **3.4.10** and Bundler **2.6.9** (see the Ruby version and bundle lockfiles).
- Node.js **22 LTS**, Yarn **1.22.22**, and PostgreSQL **16** or newer.
- A Google Cloud project with billing, **Geocoding API** and **Routes API** enabled.
- Chrome/Chromium for the browser test. Selenium manages the driver.

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
export GOOGLE_MAPS_API_KEY='your-server-api-key'
bin/rails server
```

Open <http://localhost:3000>. `bin/setup` installs locked JavaScript dependencies,
builds assets, and prepares the database. For frontend development, run
`yarn build --watch` in a second terminal. No separate webpack server is needed.

Rails also accepts `DATABASE_URL` when PostgreSQL is not available through a
local socket. Use a separate database for tests. No application records or seed
data are required.

`GOOGLE_MAPS_API_KEY` takes precedence over the existing encrypted credential
`google_maps_key`. The environment variable alone is sufficient; you do not
need the original application's credentials or master key. Never commit keys.
The server key is not sent to browsers, asset bundles, or rendered image URLs.
Restrict it to the two required APIs and your server's egress IP addresses.
Configure billing alerts and quotas before exposing the application publicly.

## External services and changed behavior

The previous implementation depended on the legacy Hiking Project API. This
version instead queries hiking-route relations from
[OpenStreetMap via Overpass](https://wiki.openstreetmap.org/wiki/Overpass_API).
It does not scrape Hiking Project or require its old API key.
Current Hiking Project availability could not be confirmed. Live probes of both
trail providers were blocked by DNS restrictions in the modernization environment;
test Overpass connectivity from your deployment before launching.

- Searches cover routes intersecting a **25 km** radius around the geocoded origin.
- Up to **100** relations are read; the nearest **10** matching route starts are
  checked for transit access. Results are not an exhaustive trail inventory.
- Lengths are approximate, calculated from deduplicated mapped way geometry.
  Nested or incomplete routes are skipped. A mapped route start is not necessarily
  an official or accessible trailhead: check the route and local conditions.
- The **1–30 mile** filter applies to the hiking route, not the transit journey.
- Only routes with a transit itinerary are displayed, sorted by travel time.
  Arrival must be in the future and within **7 days**, in the displayed Rails
  timezone (UTC by default).
- Missing photos and elevation are omitted rather than fabricated. The old
  Street View fallback was removed so a server API key is never exposed in HTML.
- Provider failures produce a friendly error, not misleading empty results.

Route data is © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the ODbL. The public Overpass server is shared infrastructure:
follow its [usage guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
For significant traffic, arrange dedicated capacity and suitable caching rather
than relying on this public instance. Provider calls have bounded timeouts and
result limits, but searches involve multiple HTTP requests.

Google integration uses the current
[Routes transit API](https://developers.google.com/maps/documentation/routes/transit-route)
and [Geocoding API](https://developers.google.com/maps/documentation/geocoding/overview),
not legacy Directions. Transit coverage depends on local schedules and Google.
Follow Google's [attribution and usage policies](https://developers.google.com/maps/documentation/routes/policies)
and publish the required terms of use and privacy policy for your deployment.
Do not persist Google response data without checking the applicable policies.
Provider outages and paid API credentials cannot be validated by offline tests;
perform a real search with your restricted key before launching.

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

Service and request tests use deterministic provider doubles: no paid API key or
external API traffic is required. Tests cover input validation, route filtering,
sorting, empty results, malformed responses, and upstream failures. The browser
test checks that the search form and bundled Bootstrap styles load.

GitHub Actions runs these checks against PostgreSQL. Dependabot checks Ruby,
JavaScript, and GitHub Actions dependencies weekly. Commit both lockfiles when
updating dependencies.

## Production deployment

1. Install the pinned Ruby/Node toolchains and locked dependencies:
   `bundle install` and `yarn install --frozen-lockfile`.
   esbuild is a development dependency but must be installed in the build stage.
2. Compile assets using
   `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`.
   Do **not** set `SECRET_KEY_BASE_DUMMY` in the running server.
3. Supply `RAILS_ENV=production`, `DATABASE_URL`, a stable securely generated
   `SECRET_KEY_BASE`, and `GOOGLE_MAPS_API_KEY` through the host's secret manager.
   Use `RAILS_MASTER_KEY` only if using encrypted credentials.
4. Run `bin/rails db:prepare`, then `bundle exec puma -C config/puma.rb`.
5. Terminate HTTPS at a trusted proxy and forward the original protocol correctly.
   Production enforces HTTPS. Set `RAILS_SERVE_STATIC_FILES=1` when Rails, rather
   than the proxy, should serve precompiled assets, and `RAILS_LOG_TO_STDOUT=1`
   for container logs.

Set request/concurrency limits at the proxy, API quotas, and monitoring before
public launch. Allow sufficient upstream request time for route searches.
Back up any existing database and credentials and test on staging before replacing
an old deployment. Rails defaults have changed from 6.0 to 8.1; existing browser
sessions may need to be renewed.
