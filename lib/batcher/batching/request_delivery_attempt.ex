defmodule Batcher.Batching.RequestDeliveryAttempt do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  alias Batcher.Batching

  sqlite do
    table "request_delivery_attempts"
    repo Batcher.Repo

    references do
      reference :request, on_delete: :delete
    end

    custom_indexes do
      index [:request_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:request_id, :outcome, :delivery_config, :error_msg]

      validate Batching.Validations.DeliveryConfig
      primary? true
    end

    read :list_paginated do
      description "List delivery attempts with pagination support"
      argument :request_id, :integer, allow_nil?: false
      argument :skip, :integer, allow_nil?: false, default: 0
      argument :limit, :integer, allow_nil?: false, default: 25
      filter expr(request_id == ^arg(:request_id))

      prepare fn query, _ ->
        Ash.Query.sort(query, attempted_at: :desc)
      end

      pagination offset?: true, countable: true
    end
  end

  pub_sub do
    module BatcherWeb.Endpoint

    prefix "request_delivery_attempts"
    publish :create, ["created", :request_id]
  end

  attributes do
    integer_primary_key :id

    attribute :outcome, Batching.Types.RequestDeliveryAttemptOutcome do
      description "The outcome of the delivery attempt"
      allow_nil? false
    end

    attribute :delivery_config, :map do
      description "The configuration of the delivery attempt"
      allow_nil? false
    end

    attribute :error_msg, :string do
      description "Error message if the delivery attempt was unsuccessful"
      allow_nil? true
    end

    create_timestamp :attempted_at
  end

  relationships do
    belongs_to :request, Batching.Request do
      allow_nil? false
    end
  end
end
