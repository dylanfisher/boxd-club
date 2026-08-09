# Multi-stage: native toolchains stay out of the runtime image.
#
# There is no asset pipeline, so this should build in well under a minute.
# nokogiri and sqlite3 both resolve to precompiled Linux binaries via the
# lockfile — if a build ever starts compiling C, that's the regression to look
# at, not a reason to add more -dev packages.

FROM ruby:4.0.6-slim AS builder

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
# `deployment true` would install into ./vendor/bundle, which the runtime stage
# below does not copy. Use frozen instead: same lockfile enforcement, gems stay
# in /usr/local/bundle.
RUN bundle config set --local without development:test \
 && bundle config set --local frozen true \
 && bundle install --jobs 4 --retry 3 \
 && rm -rf /usr/local/bundle/cache


FROM ruby:4.0.6-slim

# libjemalloc2 must be installed HERE, not just in the builder — otherwise
# LD_PRELOAD fails silently and the memory win disappears with no error.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends libjemalloc2 \
 && rm -rf /var/lib/apt/lists/*

# Bare soname, so the loader resolves it on either amd64 or arm64.
ENV LD_PRELOAD=libjemalloc.so.2 \
    MALLOC_ARENA_MAX=2 \
    RACK_ENV=production
# Deliberately no BUNDLE_PATH: the base image sets GEM_HOME=/usr/local/bundle,
# and setting BUNDLE_PATH puts bundler in path mode, where it looks for a
# ruby/<abi>/gems/ subdirectory that doesn't exist. BUNDLE_WITHOUT and
# BUNDLE_FROZEN come across in /usr/local/bundle/config from the builder.

WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

# The database lives on a mounted volume; this only matters for a bare
# `docker run` without one.
RUN mkdir -p db/backups db/avatars

EXPOSE 5000
CMD ["bundle", "exec", "puma", "-p", "5000", "-t", "2:3"]
