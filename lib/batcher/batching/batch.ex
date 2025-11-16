defmodule Batcher.Batching.Batch do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban]

  alias Batcher.Batching

  sqlite do
    table "batches"
    repo Batcher.Repo
  end

  state_machine do
    initial_states [:building]
    default_initial_state :building

    transitions do
      transition :start_upload, from: :building, to: :uploading
      transition :upload, from: :uploading, to: :uploaded
      transition :create_openai_batch, from: :uploaded, to: :openai_batch_created
      transition :openai_validating, from: :openai_batch_created, to: :openai_validating
      transition :openai_processing, from: :openai_validating, to: :openai_processing
      transition :openai_completed, from: :openai_processing, to: :openai_completed
      transition :downloading, from: :openai_completed, to: :downloading
      transition :downloaded, from: :downloading, to: :downloaded
      transition :ready_to_deliver, from: :downloaded, to: :ready_to_deliver
      transition :delivering, from: :ready_to_deliver, to: :delivering
      transition :completed, from: :delivering, to: :completed

      transition :failed,
        from: [
          :building,
          :uploading,
          :uploaded,
          :openai_batch_created,
          :openai_validating,
          :openai_processing,
          :openai_completed,
          :downloading,
          :downloaded,
          :ready_to_deliver,
          :delivering
        ],
        to: :failed
    end
  end

  oban do
    triggers do
      trigger :upload do
        action :upload
        queue :batch_uploads
        where expr(state == :uploading)
        worker_module_name Batching.Batch.AshOban.Worker.UploadBatch
        scheduler_module_name Batching.Batch.AshOban.Scheduler.UploadBatch
      end

      trigger :create_openai_batch do
        action :create_openai_batch
        where expr(state == :uploaded)
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.CreateOpenaiBatch
        scheduler_module_name Batching.Batch.AshOban.Scheduler.CreateOpenaiBatch
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new batch for OpenAI"
      accept [:model, :endpoint]
    end

    read :find_building_batch do
      description "Find a draft batch for the given model and endpoint"
      argument :model, :string, allow_nil?: false
      argument :endpoint, :string, allow_nil?: false
      filter expr(state == :building and model == ^arg(:model) and endpoint == ^arg(:endpoint))
      get? true
    end

    update :start_upload do
      description "Start upload process for the batch"
      require_atomic? false
      change transition_state(:uploading)
      change run_oban_trigger(:upload)
    end

    update :upload do
      description "Upload batch file to OpenAI"
      require_atomic? false
      change Batcher.Batching.Changes.UploadBatchFile
      change transition_state(:uploaded)
      change run_oban_trigger(:create_openai_batch)
    end

    update :create_openai_batch do
      description "Create batch on OpenAI platform for processing"
      require_atomic? false
      change Batcher.Batching.Changes.CreateOpenaiBatch
      change transition_state(:openai_batch_created)
    end

    # Add all missing state transition actions
    update :openai_validating do
      change transition_state(:openai_validating)
      require_atomic? false
    end

    update :openai_processing do
      change transition_state(:openai_processing)
      require_atomic? false
    end

    update :openai_completed do
      change transition_state(:openai_completed)
      require_atomic? false
    end

    update :downloading do
      change transition_state(:downloading)
      require_atomic? false
    end

    update :downloaded do
      change transition_state(:downloaded)
      require_atomic? false
    end

    update :ready_to_deliver do
      change transition_state(:ready_to_deliver)
      require_atomic? false
    end

    update :delivering do
      change transition_state(:delivering)
      require_atomic? false
    end

    update :completed do
      change transition_state(:completed)
      require_atomic? false
    end

    update :failed do
      accept [:error_msg]
      change transition_state(:failed)
      require_atomic? false
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
      default :building
    end

    attribute :openai_file_id, :string do
      description "File ID given by the OpenAI API"
    end

    attribute :openai_batch_id, :string do
      description "Batch ID given by the OpenAI API"
    end

    attribute :endpoint, :string do
      description "OpenAI Batch API endpoint (e.g., /v1/responses)"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "Model name - all prompts in batch must use same model"
      allow_nil? false
      public? true
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
