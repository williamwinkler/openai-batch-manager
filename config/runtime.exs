import Config
import Dotenvy

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

if config_env() != :test do
  source!([Path.absname(".env"), System.get_env()])
  openai_api_key = env!("OPENAI_API_KEY", :string)

  config :batcher, Batcher.OpenaiApiClient, openai_api_key: openai_api_key

  # RabbitMQ configuration (optional)
  # - RABBITMQ_URL: Enables RabbitMQ publisher for output delivery
  # - RABBITMQ_INPUT_QUEUE: Enables RabbitMQ consumer for input (requires RABBITMQ_URL)
  rabbitmq_url = env!("RABBITMQ_URL", :string, nil)
  rabbitmq_input_queue = env!("RABBITMQ_INPUT_QUEUE", :string, nil)

  # Publisher: enabled when RABBITMQ_URL is set (used for output delivery)
  if rabbitmq_url do
    config :batcher, :rabbitmq_publisher, url: rabbitmq_url
  end

  # Consumer: enabled when both RABBITMQ_URL and RABBITMQ_INPUT_QUEUE are set
  if rabbitmq_url && rabbitmq_input_queue do
    # Exchange and routing_key are optional for binding to an exchange
    # If exchange is set, routing_key must also be set
    rabbitmq_input_exchange = env!("RABBITMQ_INPUT_EXCHANGE", :string, nil)
    rabbitmq_input_routing_key = env!("RABBITMQ_INPUT_ROUTING_KEY", :string, nil)

    if rabbitmq_input_exchange && !rabbitmq_input_routing_key do
      raise "RABBITMQ_INPUT_ROUTING_KEY is required when RABBITMQ_INPUT_EXCHANGE is set"
    end

    config :batcher, :rabbitmq_input,
      url: rabbitmq_url,
      queue: rabbitmq_input_queue,
      exchange: rabbitmq_input_exchange,
      routing_key: rabbitmq_input_routing_key
  end
end

# Batch storage configuration
# Production: /var/lib/batcher/batches (Docker volume mount point)
# Dev/Test: tmp/batches (local writable directory)
# Can be overridden with BATCH_STORAGE_PATH environment variable
default_batch_path =
  cond do
    System.get_env("BATCH_STORAGE_PATH") ->
      System.get_env("BATCH_STORAGE_PATH")

    config_env() == :prod ->
      "/var/lib/batcher/batches"

    config_env() == :test ->
      Path.expand("../tmp/test_batches", __DIR__)

    true ->
      # Dev environment - use local tmp directory
      Path.expand("../tmp/batches", __DIR__)
  end

config :batcher, :batch_storage, base_path: default_batch_path

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/batcher start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :batcher, BatcherWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/batcher/batcher.db
      """

  config :batcher, Batcher.Repo,
    database: database_path,
    # CRITICAL: SQLite only supports one writer at a time. Pool size of 1 serializes writes
    # and prevents "Database busy" errors. Override with POOL_SIZE env var if needed.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1"),
    # SQLite production optimizations
    timeout: 60_000,
    queue_target: 5_000,
    queue_interval: 1_000,
    after_connect:
      {Exqlite.Sqlite3, :execute,
       [
         """
         PRAGMA journal_mode=WAL;
         PRAGMA busy_timeout=10000;
         PRAGMA synchronous=NORMAL;
         PRAGMA cache_size=-64000;
         PRAGMA temp_store=memory;
         PRAGMA mmap_size=30000000000;
         """
       ]}

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # If not provided, we auto-generate one (fine for localhost use).
  # For production deployments, you should set SECRET_KEY_BASE explicitly
  # so it persists across restarts.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        # Auto-generate a secret key base (same method as mix phx.gen.secret)
        generated = Base.encode64(:crypto.strong_rand_bytes(64))
        require Logger

        Logger.warning(
          "SECRET_KEY_BASE not set - auto-generated a new one. " <>
            "This will change on each restart. Set SECRET_KEY_BASE explicitly for production."
        )

        generated

      value ->
        value
    end

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :batcher, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :batcher, BatcherWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    check_origin: false,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :batcher, BatcherWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :batcher, BatcherWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :batcher, Batcher.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
