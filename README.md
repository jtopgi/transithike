# TransitHike

Find nearby hiking routes reachable by public transit, ordered by estimated
travel time. The application is Rails-rendered and retains its original simple
search form and results cards.

## Requirements

- Ruby **3.4.10** and Bundler **2.6.9** (see the Ruby version and bundle lockfiles).
- Node.js **22 LTS**, Yarn **1.22.22**, and PostgreSQL **16** or newer.
- Chrome/Chromium for the browser test. Selenium manages the driver.
- Internet access for searches. No API keys or paid accounts are needed: place
  search and transit routing use [Transitous](https://transitous.org) and route
  data comes from OpenStreetMap.

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

- Searches cover routes intersecting a **25 km** radius around the geocoded origin.
- Up to **100** relations are read; the nearest **10** matching route starts are
  checked for transit access. Results are not an exhaustive trail inventory.
- Lengths are approximate, calculated from deduplicated mapped way geometry.
  Nested or incomplete routes are skipped. A mapped route start is not necessarily
  an official or accessible trailhead: check the route and local conditions.
- The **1–30 mile** filter applies to the hiking route, not the transit journey.
- Only routes reachable by public transit, or by a direct walk of up to 30
  minutes, are displayed, sorted by travel time. Journeys may include up to
  15 minutes' walk to the first stop and 30 minutes from the last stop.
  Arrival must be in the future and within **7 days**, in the displayed Rails
  timezone (UTC by default).
- Missing photos and elevation are omitted rather than fabricated.
- Provider failures produce a friendly error, not misleading empty results.

Route data is © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the ODbL. The public Overpass server is shared infrastructure:
follow its [usage guidance](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html).
For significant traffic, arrange dedicated capacity and suitable caching rather
than relying on this public instance. Provider calls have bounded timeouts and
result limits, but searches involve multiple HTTP requests. Validated OSM responses
are cached by coordinates for **15 minutes** using Rails' cache; production uses
a bounded, process-local memory store. Processes do not share that cache.
Failures are never cached.

Place search and transit travel times come from [Transitous](https://transitous.org),
a free, community-run [MOTIS](https://github.com/motis-project/motis) service
built on open timetable feeds and OpenStreetMap. It needs no API key, but its
[usage policy](https://transitous.org/api/) applies: the code must stay open
source (this repository is MIT-licensed), use must be non-commercial, results
link to its [data sources](https://transitous.org/sources/), and requests identify
the app with `SearchHttp::USER_AGENT` (change it if you fork). Contact the
maintainers in their [Matrix room](https://matrix.to/#/%23transitous:matrix.spline.de)
before sending substantial routing traffic. Each search makes one place search
and up to ten routing requests; place results are cached for a day and routing
results for 15 minutes. Transit coverage depends on the feeds Transitous has for
a region. The results page names the matched origin so users can refine
ambiguous searches. The Directions link opens Google Maps' public directions
page, which needs no API key. Provider outages cannot be validated by offline
tests; perform a real search before launching.

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

Service and request tests use deterministic provider doubles: no external API
traffic is required. Tests cover input validation, route filtering,
sorting, empty results, malformed responses, and upstream failures. The browser
test checks that the search form and bundled Bootstrap styles load.

GitHub Actions runs these checks against PostgreSQL, and builds the production
container image and smoke-tests it without a database. Dependabot checks Ruby,
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

The app runs on [Azure Container Apps](https://learn.microsoft.com/azure/container-apps/)
and deploys from GitHub Actions:

- After CI passes on `master`, the `deploy` job signs in to Azure with OpenID
  Connect (no stored passwords), pushes the image to Azure Container Registry
  tagged with the commit SHA, and updates the container app. Deployments and the
  app URL appear under the repository's `production` environment.
- Images are built by GitHub Actions because Azure free-credit subscriptions
  cannot use Container Registry build tasks.
- The app scales to zero when idle, so the first request after a quiet period
  takes 10–20 seconds while it starts. It runs at most one 0.5 vCPU/1 GiB replica.
  Logs go to Log Analytics with 30-day retention and a 0.1 GB daily cap.

Expected cost is about **US$5/month** for the Basic registry; light traffic stays
within the Container Apps monthly free grant. Keeping one replica running
(`--min-replicas 1`) adds roughly US$10/month.

### One-time setup

Install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
and [GitHub CLI](https://cli.github.com/), then run:

```sh
az login
bin/azure-setup
```

The idempotent script creates the `rg-transithike` resource group with the
registry, Log Analytics workspace, Container Apps environment and app, and two
managed identities: one pulls images, and the other is trusted only by this
repository's `production` GitHub environment to deploy. It stores a generated
`SECRET_KEY_BASE` as a Container Apps secret and restricts that GitHub
environment to the default branch. Push or merge to `master` to deploy.

### Operations

```sh
az containerapp logs show -n transithike -g rg-transithike --follow     # stream logs
az containerapp update -n transithike -g rg-transithike --min-replicas 1  # stay warm
az containerapp update -n transithike -g rg-transithike \
  --image <registry>.azurecr.io/transithike:<previous-sha>                # roll back
az group delete -n rg-transithike                                         # remove everything
```

## License

[MIT](LICENSE)
