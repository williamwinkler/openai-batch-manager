# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Store env for runtime (e.g. Application.start); config_env() is only valid during config load.
config :batcher, :env, config_env()

config :batcher, Batcher.Clients.OpenAI.ApiClient, base_url: "https://api.openai.com"

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash_oban, pro?: false

config :batcher, Oban,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, batch_uploads: 1, batch_processing: 1, capacity_dispatch: 1, delivery: 24],
  repo: Batcher.Repo,
  # Keep polling moderate under heavy queue load
  poll_interval: 1_000,
  plugins: [
    {Oban.Plugins.Cron, []},
    # Rescue jobs left in `executing` after node restarts/crashes.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(2)},
    # Prune completed jobs older than 1 day every hour
    {Oban.Plugins.Pruner, max_age: 86_400, interval: 3600}
  ]

# BatchBuilder configuration
config :batcher, Batcher.Batching.BatchBuilder,
  max_age_hours: 1,
  check_interval_minutes: 5

config :batcher, :token_estimation,
  request_safety_buffer: 1.10,
  safety_buffer: 1.10,
  fallback_chars_per_token: 3.5,
  max_tokenizer_payload_bytes: 200_000

config :batcher, :capacity_control,
  default_unknown_model_batch_limit_tokens: 250_000,
  capacity_recheck_cron: "*/1 * * * *"

config :batcher, :ui_batch_reload_coalesce_ms, 1_500

config :batcher, :openai_rate_limits_enabled, true

config :ash,
  default_belongs_to_type: :integer,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :json_api,
        :admin,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :json_api,
        :admin,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

config :batcher,
  ecto_repos: [Batcher.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Batcher.Batching, Batcher.Settings]

# Configures the endpoint
config :batcher, BatcherWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BatcherWeb.ErrorHTML, json: BatcherWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Batcher.PubSub,
  live_view: [signing_salt: "I8IPpsNL"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  batcher: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  batcher: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use JSON for JSON parsing in Phoenix
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
