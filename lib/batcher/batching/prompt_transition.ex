defmodule Batcher.Batching.PromptTransition do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer

  alias Batcher.Batching

  sqlite do
    table "prompt_transitions"
    repo Batcher.Repo

    references do
      reference :prompt, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:prompt_id, :from, :to]
      primary? true
    end
  end

  attributes do
    integer_primary_key :id

    attribute :from, Batching.Types.PromptStatus do
      description "Previous status (nil for initial creation)"
      allow_nil? true
    end

    attribute :to, Batching.Types.PromptStatus do
      description "New status after transition"
      allow_nil? false
    end

    create_timestamp :transitioned_at
  end

  relationships do
    belongs_to :prompt, Batching.Prompt do
      allow_nil? false
    end
  end
end
