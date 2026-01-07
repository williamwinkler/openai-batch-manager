import Config
config :batcher, Oban, testing: :manual
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :batcher, Batcher.OpenaiApiClient, openai_api_key: "sk-test-dummy-key"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :batcher, Batcher.Repo,
  database: Path.expand("../batcher_test.db", __DIR__),
  # Reduced pool size to reduce contention under heavy system load
  pool_size: 3,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite-specific settings for better concurrency
  timeout: 60_000,
  # Enable WAL mode and increase busy timeout for concurrent writes
  # Higher busy_timeout helps when system is under heavy load
  # Additional pragmas for better performance under load
  after_connect:
    {Exqlite.Sqlite3, :execute,
     [
       """
       PRAGMA journal_mode=WAL;
       PRAGMA busy_timeout=30000;
       PRAGMA synchronous=NORMAL;
       PRAGMA cache_size=-64000;
       PRAGMA temp_store=MEMORY;
       """
     ]}

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

# Suppress log messages during test (errors are expected in error-handling tests)
config :logger, level: :none

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use smaller batch limits for testing to make edge case testing feasible
config :batcher, :batch_limits,
  max_requests_per_batch: 5,
  max_batch_size_bytes: 1024 * 1024
