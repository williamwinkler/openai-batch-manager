defmodule Batcher.Batching.Batch do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban],
    notifiers: [Ash.Notifier.PubSub]

  require Ash.Resource.Change.Builtins
  require Ash.Query

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
      transition :create_openai_batch, from: [:uploaded, :expired], to: :openai_processing
      transition :mark_expired, from: :openai_processing, to: :expired
      transition :openai_processing_completed, from: :openai_processing, to: :openai_completed
      transition :start_downloading, from: :openai_completed, to: :downloading
      transition :finalize_processing, from: :downloading, to: :ready_to_deliver
      transition :start_delivering, from: :ready_to_deliver, to: :delivering
      transition :done, from: :delivering, to: :done

      transition :failed,
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

      transition :cancel,
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
      trigger :expire_stale_building_batch do
        action :expire_stale_building_batch
        where expr(state == :building and created_at < datetime_add(now(), -1, "hour"))
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.ExpireStaleBuildingBatch
        scheduler_module_name Batching.Batch.AshOban.Scheduler.ExpireStaleBuildingBatch
      end

      trigger :upload do
        action :upload
        queue :batch_uploads
        where expr(state == :uploading)
        worker_module_name Batching.Batch.AshOban.Worker.UploadBatch
        scheduler_module_name Batching.Batch.AshOban.Scheduler.UploadBatch
      end

      trigger :create_openai_batch do
        action :create_openai_batch
        where expr(state == :uploaded or state == :expired)
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
        # Use dedicated queue with concurrency 1 to prevent parallel downloads
        queue :batch_processing
        worker_module_name Batching.Batch.AshOban.Worker.StartDownloading
        scheduler_module_name Batching.Batch.AshOban.Scheduler.StartDownloading
      end

      trigger :process_downloaded_file do
        action :process_downloaded_file
        where expr(state == :downloading)
        # Use dedicated queue with concurrency 1 to prevent parallel processing
        queue :batch_processing
        worker_module_name Batching.Batch.AshOban.Worker.ProcessDownloadedFile
        scheduler_module_name Batching.Batch.AshOban.Scheduler.ProcessDownloadedFile
      end

      trigger :delete_expired_batch do
        action :delete_expired_batch
        where expr(expires_at < now())
        # Every hour at minute 0
        scheduler_cron "0 * * * *"
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.DeleteExpiredBatch
        scheduler_module_name Batching.Batch.AshOban.Scheduler.DeleteExpiredBatch
      end

      trigger :check_delivery_completion do
        action :check_delivery_completion
        where expr(state == :delivering)
        queue :default
        worker_module_name Batching.Batch.AshOban.Worker.CheckDeliveryCompletion
        scheduler_module_name Batching.Batch.AshOban.Scheduler.CheckDeliveryCompletion
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "Create a new batch"
      accept [:model, :url]
    end

    read :find_building_batch do
      description "Find a batch for the given model and url in the state of building"
      argument :model, :string, allow_nil?: false
      argument :url, :string, allow_nil?: false
      filter expr(state == :building and model == ^arg(:model) and url == ^arg(:url))

      prepare fn query, _ ->
        Ash.Query.after_action(query, fn _query, records ->
          filtered =
            Enum.map(records, fn batch ->
              batch
              |> Ash.load!(:request_count)
              |> Ash.load!(:size_bytes)
            end)
            |> Enum.filter(fn batch ->
              batch.request_count < 50_000
            end)

          {:ok, filtered}
        end)
      end

      get? true
    end

    update :start_upload do
      description "Start upload process for the batch"
      require_atomic? false
      change Batching.Changes.EnsureBatchHasRequests
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

    action :check_batch_status, :struct do
      description "Check status of OpenAI batch processing"
      constraints instance_of: __MODULE__
      transaction? false
      run Batching.Actions.CheckBatchStatus
    end

    update :set_openai_status_last_checked do
      require_atomic? false
      change set_attribute(:openai_status_last_checked_at, &DateTime.utc_now/0)
    end

    update :failed do
      require_atomic? false
      accept [:error_msg]
      change set_attribute(:openai_status_last_checked_at, &DateTime.utc_now/0)
      change transition_state(:failed)
    end

    update :openai_processing_completed do
      description "Mark batch as completed processing on OpenAI"
      require_atomic? false

      accept [
        :openai_output_file_id,
        :openai_error_file_id,
        :input_tokens,
        :cached_tokens,
        :reasoning_tokens,
        :output_tokens
      ]

      change set_attribute(:openai_status_last_checked_at, &DateTime.utc_now/0)
      change transition_state(:openai_completed)
      change run_oban_trigger(:start_downloading)
    end

    update :start_downloading do
      require_atomic? false
      change transition_state(:downloading)
      change run_oban_trigger(:process_downloaded_file)
    end

    action :process_downloaded_file, :struct do
      description "Downloads the file, updates all requests, and marks batch as ready for delivery."
      constraints instance_of: __MODULE__
      # Downloads can be large; avoid long transactions
      transaction? false
      run Batching.Actions.ProcessDownloadedFile
    end

    update :finalize_processing do
      description "Mark batch as ready to deliver after processing downloaded results"
      require_atomic? false
      change transition_state(:ready_to_deliver)
    end

    update :start_delivering do
      description "Start delivering the results back"
      require_atomic? false
      change transition_state(:delivering)
    end

    update :done do
      change transition_state(:done)
      require_atomic? false
    end

    update :cancel do
      require_atomic? false
      change Batching.Changes.CancelBatch
      change transition_state(:cancelled)
    end

    action :expire_stale_building_batch, :struct do
      description "Expire stale building batches, deleting empty ones"
      constraints instance_of: __MODULE__
      transaction? false
      run Batching.Actions.ExpireStaleBuildingBatch
    end

    update :mark_expired do
      description "Mark batch as expired from OpenAI and reschedule"
      require_atomic? false
      change set_attribute(:openai_status_last_checked_at, nil)
      change set_attribute(:expires_at, nil)
      change set_attribute(:openai_batch_id, nil)
      change transition_state(:expired)
      change run_oban_trigger(:create_openai_batch)
    end

    action :check_delivery_completion, :struct do
      description "Check if all requests are delivered and transition to done"
      constraints instance_of: __MODULE__
      transaction? false
      run Batching.Actions.CheckDeliveryCompletion
    end

    action :delete_expired_batch, :struct do
      description "Delete batches that have passed their expiration date"
      constraints instance_of: __MODULE__
      transaction? false
      run Batching.Actions.DeleteExpiredBatch
    end

    destroy :destroy do
      description "Destroy a batch, notifying BatchBuilder, cancelling OpenAI batch if needed, and deleting OpenAI files"
      primary? true
      require_atomic? false
      change Batching.Changes.CleanupOnDestroy
    end
  end

  pub_sub do
    module BatcherWeb.Endpoint

    prefix "batches"
    publish :start_upload, ["started_uploading", :id]
    publish :destroy, ["destroyed", :id]

    publish_all :update, ["state_changed", :id],
      filter: fn notification ->
        # Only publish if state attribute changed
        Ash.Changeset.changing_attribute?(notification.changeset, :state)
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

    attribute :openai_error_file_id, :string do
      description "File ID given by the OpenAI API for failed requests (if any)"
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

    attribute :expires_at, :utc_datetime do
      description "The datetime of when the batch will expire and be deleted"
    end

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

  calculations do
    calculate :request_count, :integer, Batcher.Batching.Calculations.BatchRequestCount
    calculate :size_bytes, :integer, Batcher.Batching.Calculations.BatchSizeBytes

    calculate :requests_terminal_count,
              :integer,
              Batcher.Batching.Calculations.BatchRequestsTerminal
  end
end
