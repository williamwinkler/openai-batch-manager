defmodule Batcher.Batching.Batch do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine]

  alias Batcher.Batching

  sqlite do
    table "batches"
    repo Batcher.Repo
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      # Normal workflow
      transition :mark_ready, from: :draft, to: :ready_for_upload
      transition :begin_upload, from: :ready_for_upload, to: :uploading
      transition :mark_validating, from: :uploading, to: :validating
      transition :mark_in_progress, from: :validating, to: :in_progress
      transition :mark_finalizing, from: :in_progress, to: :finalizing
      transition :begin_download, from: :finalizing, to: :downloading
      transition :mark_completed, from: :downloading, to: :completed

      # Failure transitions
      transition :mark_failed,
        from: [
          :draft,
          :ready_for_upload,
          :uploading,
          :validating,
          :in_progress,
          :finalizing,
          :downloading
        ],
        to: :failed

      transition :mark_expired, from: [:validating, :in_progress, :finalizing], to: :expired

      transition :cancel,
        from: [:draft, :ready_for_upload, :uploading, :validating],
        to: :cancelled
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new batch"
      accept [:provider, :model]
      change Batching.Changes.CreateBatchFile
    end

    # Transition actions
    update :mark_ready do
      require_atomic? false
      change transition_state(:ready_for_upload)
    end

    update :begin_upload do
      require_atomic? false
      change transition_state(:uploading)
    end

    update :mark_validating do
      accept [:provider_batch_id]
      require_atomic? false
      change transition_state(:validating)
    end

    update :mark_in_progress do
      require_atomic? false
      change transition_state(:in_progress)
    end

    update :mark_finalizing do
      require_atomic? false
      change transition_state(:finalizing)
    end

    update :begin_download do
      require_atomic? false
      change transition_state(:downloading)
    end

    update :mark_completed do
      require_atomic? false
      change transition_state(:completed)
    end

    update :mark_failed do
      accept [:error_msg]
      require_atomic? false
      change transition_state(:failed)
    end

    update :mark_expired do
      accept [:error_msg]
      require_atomic? false
      change transition_state(:expired)
    end

    update :cancel do
      require_atomic? false
      change transition_state(:cancelled)
    end
  end

  changes do
    change {Batching.Changes.CreateTransition,
            transition_resource: Batching.BatchTransition,
            parent_id_field: :batch_id,
            state_attribute: :state},
           where: [changing(:state)]
  end

  attributes do
    integer_primary_key :id

    attribute :state, Batching.Types.BatchStatus do
      description "Current state of the batch"
      allow_nil? false
      default :draft
    end

    attribute :provider_batch_id, :string do
      description "Batch ID given by the provider"
    end

    attribute :provider, Batching.Types.Provider do
      allow_nil? false
      description "LLM provider: openai (only one supported atm)"
    end

    attribute :model, :string do
      description "Model name - all prompts in batch must use same model"
    end

    attribute :error_msg, :string do
      description "Error message if batch failed"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :prompts, Batching.Prompt do
      description "Prompts included in this batch"
      public? true
    end

    has_many :transitions, Batching.BatchTransition do
      description "Audit trail of status transitions"
    end
  end
end
