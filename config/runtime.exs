import Config
import Dotenvy

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

if config_env() != :test do
  env_dir_prefix = System.get_env("RELEASE_ROOT") || Path.expand(".")

  source!([
    Path.absname(".env", env_dir_prefix),
    Path.absname(".#{config_env()}.env", env_dir_prefix),
    Path.absname(".#{config_env()}.overrides.env", env_dir_prefix),
    System.get_env()
  ])

  openai_api_key = env!("OPENAI_API_KEY", :string)
  rabbitmq_url = env!("RABBITMQ_URL", :string, nil)
  rabbitmq_input_queue = env!("RABBITMQ_INPUT_QUEUE", :string, nil)
  rabbitmq_input_exchange = env!("RABBITMQ_INPUT_EXCHANGE", :string, nil)
  rabbitmq_input_routing_key = env!("RABBITMQ_INPUT_ROUTING_KEY", :string, nil)

  config :batcher, Batcher.OpenaiApiClient, openai_api_key: openai_api_key

  # RabbitMQ configuration (optional)
  # - RABBITMQ_URL: Enables RabbitMQ publisher for output delivery
  # - RABBITMQ_INPUT_QUEUE: Enables RabbitMQ consumer for input (requires RABBITMQ_URL)
  # Publisher: enabled when RABBITMQ_URL is set (used for output delivery)
  if rabbitmq_url do
    config :batcher, :rabbitmq_publisher, url: rabbitmq_url
  end

  # Consumer: enabled when both RABBITMQ_URL and RABBITMQ_INPUT_QUEUE are set
  if rabbitmq_url && rabbitmq_input_queue do
    # Exchange and routing_key are optional for binding to an exchange
    # If exchange is set, routing_key must also be set
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

# Delivery retry toggle
# - DISABLE_DELIVERY_RETRY=true: force delivery to a single attempt (no retries)
disable_delivery_retry? =
  case System.get_env("DISABLE_DELIVERY_RETRY") do
    value when value in ["1", "true", "TRUE", "yes", "YES"] -> true
    _ -> false
  end

config :batcher, :disable_delivery_retry, disable_delivery_retry?

# Batch storage: hardcoded paths per environment
default_batch_path =
  cond do
    config_env() == :prod -> "/data/batches"
    config_env() == :test -> Path.expand("../tmp/test_batches", __DIR__)
    true -> Path.expand("../tmp/batches", __DIR__)
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
  config :batcher, Batcher.Repo,
    database: System.get_env("DATABASE_PATH", "/data/openai-batch-manager.db"),
    pool_size: 1,
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

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :batcher, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :batcher, BatcherWeb.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
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
