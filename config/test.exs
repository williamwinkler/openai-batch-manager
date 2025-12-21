import Config
config :batcher, Oban, testing: :manual
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :batcher, Batcher.OpenaiApiClient,
  openai_api_key: "sk-test-dummy-key"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :batcher, Batcher.Repo,
  database: Path.expand("../batcher_test.db", __DIR__),
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite-specific settings for better concurrency
  timeout: 60_000,
  # Enable WAL mode and increase busy timeout for concurrent writes
  after_connect:
    {Exqlite.Sqlite3, :execute, ["PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"]}

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :batcher, BatcherWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Y0Y1py+gvgK/NxuoT/LGpxnHqaZPvAJuPhiDGOdGEE/1gDYH2kLtqX9K9hFNeyyQ",
  server: false

# In test we don't send emails
config :batcher, Batcher.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
