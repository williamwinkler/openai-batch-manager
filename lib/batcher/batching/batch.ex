defmodule Batcher.Batching.Batch do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban]

  require Ash.Resource.Change.Builtins
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
      transition :create_openai_batch, from: :uploaded, to: :openai_processing
      transition :check_batch_status, from: :openai_processing, to: :openai_completed
      transition :start_downloading, from: :openai_completed, to: :downloading
      transition :download, from: :downloading, to: :ready_to_deliver
      transition :start_delivering, from: :ready_to_deliver, to: :delivering
      transition :done, from: :delivering, to: :done

      transition :check_batch_status,
        from: [
          :building,
          :uploading,
          :uploaded,
          :openai_processing,
          :openai_completed,
          :downloading,
          :downloaded,
          :ready_to_deliver,
          :delivering
        ],
        to: :failed

      transition :check_batch_status,
        from: [
          :building,
          :uploading,
          :uploaded,
          :openai_processing,
          :openai_completed,
          :downloading,
          :downloaded,
          :ready_to_deliver,
          :delivering
        ],
        to: :cancelled
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

      trigger :check_batch_status do
        action :check_batch_status
        where expr(state == :openai_processing)
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.CheckBatchStatus
        scheduler_module_name Batching.Batch.AshOban.Scheduler.CheckBatchStatus
      end

      trigger :start_downloading do
        action :start_downloading
        where expr(state == :openai_completed)
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.StartDownloading
        scheduler_module_name Batching.Batch.AshOban.Scheduler.StartDownloading
      end

      trigger :download_and_process do
        action :download_and_process
        where expr(state == :downloading)
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.DownloadAndProcess
        scheduler_module_name Batching.Batch.AshOban.Scheduler.DownloadAndProcess
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new batch"
      accept [:model, :url]
    end

    read :find_building_batch do
      description "Find a batch for the given model and url in the state of building"
      argument :model, :string, allow_nil?: false
      argument :url, :string, allow_nil?: false
      filter expr(state == :building and model == ^arg(:model) and url == ^arg(:url))
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
      change Batching.Changes.UploadBatchFile
      change transition_state(:uploaded)
      change run_oban_trigger(:create_openai_batch)
    end

    update :create_openai_batch do
      description "Create batch on OpenAI platform for processing"
      require_atomic? false
      change Batching.Changes.CreateOpenaiBatch
      change transition_state(:openai_processing)
      change run_oban_trigger(:check_batch_status)
    end

    update :check_batch_status do
      description "Check status of OpenAI batch processing"
      require_atomic? false
      change Batching.Changes.CheckOpenaiBatchStatus
    end

    update :start_downloading do
      require_atomic? false
      change transition_state(:downloading)
      change run_oban_trigger(:download_and_process)
    end

    action :download_and_process, :struct do
      description "Download processed batch results from OpenAI and update requests"
      # Downloads can be large; avoid long transactions
      transaction? false
      run Batching.Changes.DownloadBatchFile
    end

    update :start_delivering do
      description "Start delivering the results back"
      require_atomic? false
    end

    update :done do
      change transition_state(:done)
      require_atomic? false
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
      default :building
    end

    attribute :openai_input_file_id, :string do
      description "File ID given by the OpenAI API for the uploaded input file"
    end

    attribute :openai_output_file_id, :string do
      description "File ID given by the OpenAI API for the processed results"
    end

    attribute :openai_batch_id, :string do
      description "Batch ID given by the OpenAI API"
    end

    attribute :openai_status_last_checked_at, :utc_datetime do
      description "The datetime of when the status of the batch was last checked on OpenAIs platform"
    end

    attribute :url, Batching.Types.OpenaiBatchEndpoints do
      description "OpenAI Batch API request url (e.g., '/v1/responses')"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "Model name - all request in batch must use same model"
      allow_nil? false
      public? true
    end

    attribute :error_msg, :string do
      description "Error message if batch failed"
    end

    attribute :input_tokens, :integer
    attribute :cached_tokens, :integer
    attribute :reasoning_tokens, :integer
    attribute :output_tokens, :integer

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :requests, Batching.Request do
      description "Requests included in this batch"
      public? true
    end

    has_many :transitions, Batching.BatchTransition do
      description "Audit trail of status transitions"
    end
  end
end
