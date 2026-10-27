import Config

# The watcher's page and API. The port comes from the project's clawswap.exs at runtime (see
# Clawswap.Application); it only listens on 127.0.0.1.
config :clawswap, ClawswapWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 8790],
  url: [host: "localhost"],
  # Only this machine can reach it, and the API checks Origin itself.
  check_origin: false,
  # Signs Hologram's session cookie. Nothing secret rides on it: the page only shows the branch list.
  secret_key_base: "clawswap-local-only-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV",
  server: false

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :json_library, Jason
