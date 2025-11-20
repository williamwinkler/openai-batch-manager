defmodule Batcher.Batching.RequestTransition do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer

  alias Batcher.Batching

  sqlite do
    table "request_transitions"
    repo Batcher.Repo

    references do
      reference :request, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:request_id, :from, :to]
      primary? true
    end
  end

  attributes do
    integer_primary_key :id

    attribute :from, Batching.Types.RequestStatus do
      description "Previous status (nil for initial creation)"
      allow_nil? true
    end

    attribute :to, Batching.Types.RequestStatus do
      description "New status after transition"
      allow_nil? false
    end

    create_timestamp :transitioned_at
  end

  relationships do
    belongs_to :request, Batching.Request do
      allow_nil? false
    end
  end
end
