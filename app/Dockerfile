# Build Stage
FROM elixir:1.14-alpine as builder
ENV MIX_ENV=prod
WORKDIR /app
COPY mix.exs .
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get && mix deps.compile
COPY config config
COPY lib lib
# Create the release
RUN mix release

# Run Stage
FROM alpine:3.17
RUN apk add --no-cache openssl ncurses-libs libstdc++
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/event_tracker .

# Create directory for Mnesia data
RUN mkdir -p /app/mnesia_data

# Set environment variables
ENV HOME=/app
ENV RELEASE_DISTRIBUTION=name
ENV RELEASE_NODE=tracker@127.0.0.1

CMD ["bin/event_tracker", "start"]
