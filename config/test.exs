import Config
config :batcher, Oban, testing: :manual
config :ash, policies: [show_policy_breakdowns?: true]

config :batcher, Batcher.Clients.OpenAI.ApiClient, openai_api_key: "sk-test-dummy-key"
config :batcher, :openai_rate_limits_enabled, false

# Disable HTTP retries in tests to avoid TestServer receiving multiple requests
config :batcher, :disable_http_retries, true

config :batcher, :capacity_control,
  default_unknown_model_batch_limit_tokens: 2_000_000,
  capacity_recheck_cron: "*/1 * * * *"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :batcher, Batcher.Repo,
  url:
    System.get_env(
      "DATABASE_URL_TEST",
      "ecto://postgres:postgres@localhost:5432/batcher_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  timeout: 60_000,
  queue_target: 5_000,
  queue_interval: 1_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :batcher, BatcherWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Y0Y1py+gvgK/NxuoT/LGpxnHqaZPvAJuPhiDGOdGEE/1gDYH2kLtqX9K9hFNeyyQ",
  server: false

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

# Use very low HTTP timeouts in tests to fail fast when testing error scenarios
config :batcher, :http_timeouts,
  pool_timeout: 100,
  receive_timeout: 200,
  connect_timeout: 100

# Set delivery to 1 attempt in tests by default (existing tests expect single-attempt behavior).
# Individual retry tests override via Application.put_env(:batcher, :delivery_max_attempts, 3).
config :batcher, :delivery_max_attempts, 1

# Disable RabbitMQ consumer and publisher in tests - tests manage their own instances
# This prevents the Application from starting them automatically
config :batcher, :rabbitmq_input, nil
config :batcher, :rabbitmq_publisher, nil
