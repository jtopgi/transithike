# syntax=docker/dockerfile:1
# check=error=true

# Production image. Build and run locally with:
#   docker build -t transithike .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=$(openssl rand -hex 64) transithike
# Production forces HTTPS, so run it behind a TLS-terminating proxy that sets
# X-Forwarded-Proto (Azure App Service does).

# Keep in sync with .ruby-version and .node-version.
ARG RUBY_VERSION=3.4.10
ARG NODE_VERSION=22

# Bundle JavaScript and CSS with esbuild.
FROM docker.io/library/node:${NODE_VERSION}-slim AS javascript
WORKDIR /rails
RUN corepack enable
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY app/javascript app/javascript
RUN yarn build

FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base
WORKDIR /rails

# Install runtime packages, time zone data for origins' local times, and jemalloc
# for lower memory use.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq5 tzdata && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .
COPY --from=javascript /rails/app/assets/builds app/assets/builds

# Precompile bootsnap code and assets. JavaScript was already bundled above.
RUN bundle exec bootsnap precompile -j 1 app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 SKIP_JS_BUILD=1 ./bin/rails assets:precompile

FROM base

# Run as a non-root user that owns only the application files.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

ENV PORT="3000" \
    RAILS_LOG_TO_STDOUT="1" \
    RAILS_SERVE_STATIC_FILES="1"

# The commit this image was built from, reported in an X-App-Revision header.
ARG APP_REVISION
ENV APP_REVISION="${APP_REVISION}"

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
