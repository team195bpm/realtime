import Config

config :event_tracker, EventTracker.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true,
  # Allow connections from your Next.js frontend
  check_origin: false,
  pubsub_server: EventTracker.PubSub,
  render_errors: [formats: [json: EventTracker.ErrorJSON], layout: false]

config :logger, level: :info

import_config "#{config_env()}.exs"
