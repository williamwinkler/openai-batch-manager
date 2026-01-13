defmodule Batcher.Batching.Request do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban],
    notifiers: [Ash.Notifier.PubSub]

  alias Batcher.Batching

  sqlite do
    table "requests"
    repo Batcher.Repo

    custom_indexes do
      # Ensure custom_id is unique within a batch
      index [:custom_id, :batch_id], unique: true
      index [:batch_id]
    end

    references do
      reference :batch, on_delete: :delete
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      # Normal workflow
      transition :begin_processing, from: :pending, to: :openai_processing
      transition :bulk_begin_processing, from: :pending, to: :openai_processing
      transition :complete_processing, from: :openai_processing, to: :openai_processed
      transition :begin_delivery, from: :openai_processed, to: :delivering
      transition :complete_delivery, from: :delivering, to: :delivered

      # Failure transitions
      # :mark_failed = OpenAI processing failed (request error)
      transition :mark_failed,
        from: [:pending, :openai_processing, :openai_processed],
        to: :failed

      # :mark_delivery_failed = Webhook delivery failed (delivery error, not a request error)
      transition :mark_delivery_failed, from: :delivering, to: :delivery_failed

      transition :mark_expired, from: [:pending, :openai_processing], to: :expired
      transition :cancel, from: :pending, to: :cancelled
    end
  end

  oban do
    triggers do
      trigger :deliver do
        action :deliver
        where expr(state == :openai_processed)
        queue :delivery
        max_attempts 1
        worker_module_name Batching.Request.AshOban.Worker.Deliver
        scheduler_module_name Batching.Request.AshOban.Scheduler.Deliver
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new request in a batch"
      accept [:batch_id, :custom_id, :url, :model, :delivery_config]

      argument :request_payload, :map, allow_nil?: false

      validate Batching.Validations.BatchCanAcceptRequest
      validate Batching.Validations.DeliveryConfig

      change Batching.Changes.SetPayload

      primary? true
    end

    read :get_request_by_custom_id do
      description "Get a request by batch ID and custom ID"
      argument :batch_id, :integer, allow_nil?: false
      argument :custom_id, :string, allow_nil?: false
      filter expr(batch_id == ^arg(:batch_id) and custom_id == ^arg(:custom_id))
      get? true
    end

    read :list_requests_in_batch do
      description "List all requests in a given batch"
      argument :batch_id, :integer, allow_nil?: false
      filter expr(batch_id == ^arg(:batch_id))
    end

    read :list_paginated do
      description "List requests with pagination support"
      argument :batch_id, :integer, allow_nil?: false
      argument :skip, :integer, allow_nil?: false, default: 0
      argument :limit, :integer, allow_nil?: false, default: 25
      filter expr(batch_id == ^arg(:batch_id))

      prepare fn query, _ ->
        Ash.Query.sort(query, created_at: :desc)
      end

      pagination offset?: true, countable: true
    end

    update :begin_processing do
      description "Mark the request as being processed by OpenAI"
      change transition_state(:openai_processing)
    end

    update :bulk_begin_processing do
      require_atomic? false
      change transition_state(:openai_processing)
    end

    update :complete_processing do
      description "Adds the OpenAI response and mark the request as processed"
      accept [:response_payload]
      require_atomic? false
      change transition_state(:openai_processed)
    end

    update :begin_delivery do
      description "Start delivery of the processed request"
      require_atomic? false
      change transition_state(:delivering)
    end

    update :complete_delivery do
      description "Mark the request as delivered"
      require_atomic? false
      change transition_state(:delivered)
      change Batching.Changes.CreateDeliveryAttempt
    end

    update :mark_failed do
      description "Mark request as failed due to OpenAI processing error"
      accept [:error_msg]
      require_atomic? false
      change transition_state(:failed)
    end

    update :mark_delivery_failed do
      description "Mark request as failed due to webhook delivery error"
      require_atomic? false
      change transition_state(:delivery_failed)
      change Batching.Changes.CreateDeliveryAttempt
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

    action :deliver, :struct do
      description "Deliver the processed request to webhook or RabbitMQ"
      constraints instance_of: __MODULE__
      transaction? false
      run Batching.Actions.Deliver
      # Note: Delivery attempt creation is handled via Batching.Changes.CreateDeliveryAttempt
      # which is attached to :complete_delivery and :mark_delivery_failed actions
    end
  end

  pub_sub do
    module BatcherWeb.Endpoint

    prefix "requests"
    publish :create, ["created", :id]
    publish_all :create, ["created"]
    publish_all :update, ["state_changed", :id],
      filter: fn notification ->
        Ash.Changeset.changing_attribute?(notification.changeset, :state)
      end
  end

  attributes do
    integer_primary_key :id

    attribute :custom_id, :string do
      description "Custom identifier for the request (must be unique in it's batch)"
      allow_nil? false
      public? true
    end

    attribute :url, Batching.Types.OpenaiBatchEndpoints do
      description "OpenAI Batch API endpoint (e.g., /v1/responses)"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "Model name (e.g., gpt-4o, text-embedding-3-large)"
      allow_nil? false
      public? true
    end

    # Stored as string to easily build the batch .jsonl file
    attribute :request_payload, :string do
      description "Complete request payload as JSON"
      allow_nil? false
      public? true
    end

    attribute :request_payload_size, :integer do
      description "Size of the request payload in bytes"
      allow_nil? false
      public? true
    end

    attribute :response_payload, :map do
      description "The JSON body returned by OpenAI after processing the request"
      public? true
    end

    # State machine
    attribute :state, Batching.Types.RequestStatus do
      description "Current state of the request"
      allow_nil? false
      default :pending
      public? true
    end

    # Delivery configuration
    attribute :delivery_config, :map do
      description "Configuration for delivering the processed request"
      allow_nil? false
      public? true
    end

    attribute :error_msg, :string do
      description "Error message if processing or delivery failed"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :batch, Batching.Batch do
      description "The batch this request belongs to"
      allow_nil? false
      public? true
      attribute_public? true
    end

    has_many :delivery_attempts, Batching.RequestDeliveryAttempt do
      description "Audit trail of delivery attempts for this request"
    end
  end

  calculations do
    calculate :delivery_attempt_count,
              :integer,
              Batcher.Batching.Calculations.RequestDeliveryAttemptCount
  end
end
