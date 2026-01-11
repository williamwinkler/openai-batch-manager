defmodule Batcher.Batching.RequestDeliveryAttempt do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer

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
