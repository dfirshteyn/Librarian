# Librarian — local-first tiered memory daemon
# Multi-stage build for minimal production image on Alibaba ECS

# ---- Build stage ----
FROM hexpm/elixir:1.18.2-erlang-27.3.5-alpine-3.21 AS build

RUN apk add --no-cache \
  build-base \
  git \
  nodejs \
  npm \
  python3

WORKDIR /app

# Cache dependencies
COPY mix.exs mix.lock ./
COPY config/config.exs config/
COPY config/prod.exs config/prod.exs
COPY config/runtime.exs config/runtime.exs

ENV MIX_ENV=prod \
  HEX_OFFLINE=true

RUN mix do deps.get --only prod, deps.compile

# Build assets
COPY assets/package.json assets/package-lock.json assets/
RUN npm --prefix assets ci --omit=dev || true

COPY assets/ assets/
COPY config/ config/
RUN mix assets.deploy

# Compile
COPY lib/ lib/
COPY priv/ priv/
RUN mix compile

# Build release
RUN mix release

# ---- Production stage ----
FROM alpine:3.21 AS app

RUN apk add --no-cache \
  libstdc++ \
  ncurses-libs \
  openssl \
  ca-certificates

WORKDIR /app

COPY --from=build /app/_build/prod/rel/librarian ./

EXPOSE 4000
EXPOSE 4001

ENV PORT=4000
ENV MIX_ENV=prod

# Librarian listens on 4000 (Phoenix/API) and 4001 (WebSocket)
CMD ["bin/librarian", "start"]