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
      accept [:request_id, :type, :success, :error_msg]
      primary? true
    end
  end

  attributes do
    integer_primary_key :id

    attribute :type, Batching.Types.RequestDeliveryType do
      description "The type of delivery attempted"
      allow_nil? false
    end

    attribute :success, :boolean do
      description "Whether the delivery attempt was successful"
      allow_nil? false
    end

    attribute :error_msg, :string do
      description "Error message if the delivery attempt failed"
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
