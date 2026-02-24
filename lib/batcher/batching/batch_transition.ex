defmodule Batcher.Batching.BatchTransition do
  @moduledoc """
  Ash resource recording batch state machine transitions.
  """
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshPostgres.DataLayer

  alias Batcher.Batching

  postgres do
    table "batch_transitions"
    repo Batcher.Repo

    references do
      reference :batch, on_delete: :delete
    end

    custom_indexes do
      index [:batch_id]
      index [:batch_id, :transitioned_at]
      index [:batch_id, :to, :transitioned_at], name: "batch_transitions_processing_since_index"
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:batch_id, :from, :to]
      primary? true
    end
  end

  attributes do
    integer_primary_key :id

    attribute :from, Batching.Types.BatchStatus do
      description "Previous status (nil for initial creation)"
      allow_nil? true
    end

    attribute :to, Batching.Types.BatchStatus do
      description "New status after transition"
      allow_nil? false
    end

    create_timestamp :transitioned_at
  end

  relationships do
    belongs_to :batch, Batching.Batch do
      allow_nil? false
    end
  end
end
