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
  rabbitmq_publisher_pool_size = 4

  config :batcher, Batcher.Clients.OpenAI.ApiClient, openai_api_key: openai_api_key

  # RabbitMQ configuration (optional)
  # - RABBITMQ_URL: Enables RabbitMQ publisher for output delivery
  # - RABBITMQ_INPUT_QUEUE: Enables RabbitMQ consumer for input (requires RABBITMQ_URL)
  # Publisher: enabled when RABBITMQ_URL is set (used for output delivery)
  if rabbitmq_url do
    config :batcher, :rabbitmq_publisher,
      url: rabbitmq_url,
      pool_size: rabbitmq_publisher_pool_size

    config :batcher, :rabbitmq_publisher_pool_size, rabbitmq_publisher_pool_size
  end

  # Consumer: enabled when both RABBITMQ_URL and RABBITMQ_INPUT_QUEUE are set
  if rabbitmq_url && rabbitmq_input_queue do
    config :batcher, :rabbitmq_input,
      url: rabbitmq_url,
      queue: rabbitmq_input_queue
  end
end

delivery_queue_concurrency = 24
batch_processing_queue_concurrency = 4

oban_config = Application.get_env(:batcher, Oban, [])
oban_queues = Keyword.get(oban_config, :queues, [])

config :batcher,
       Oban,
       Keyword.put(
         oban_config,
         :queues,
         oban_queues
         |> Keyword.put(:delivery, delivery_queue_concurrency)
         |> Keyword.put(:batch_processing, batch_processing_queue_concurrency)
       )

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
  database_url = System.get_env("DATABASE_URL")

  if is_nil(database_url) or database_url == "" do
    raise "DATABASE_URL is missing. Example: ecto://postgres:postgres@postgres:5432/openai_batch_manager"
  end

  pool_size = 20

  config :batcher, Batcher.Repo,
    url: database_url,
    pool_size: pool_size,
    timeout: 60_000,
    queue_target: 5_000,
    queue_interval: 1_000

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
end
