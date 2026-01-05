defmodule Batcher.Batching.Request do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban]

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
      transition :complete_processing, from: :openai_processing, to: :openai_processed
      transition :begin_delivery, from: :openai_processed, to: :delivering
      transition :complete_delivery, from: :delivering, to: :delivered

      # Failure transitions
      transition :mark_failed,
        from: [:pending, :openai_processing, :openai_processed, :delivering],
        to: :failed

      transition :mark_expired, from: [:pending, :openai_processing], to: :expired
      transition :cancel, from: :pending, to: :cancelled
    end
  end

  # oban do
  #   triggers do
  #     # Starts the delivery process for processed requests
  #     trigger :begin_delivery do
  #       action :begin_delivery,
  #       queue: :delivery
  #       where expr(state == :openai_processed)
  #     end
  #   end
  # end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new request in a batch"
      accept [:batch_id, :custom_id, :url, :model]

      argument :request_payload, :map, allow_nil?: false
      argument :delivery, :map, allow_nil?: false

      validate Batching.Validations.BatchCanAcceptRequest

      change Batching.Changes.SetDeliveryConfig
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

    update :begin_processing do
      description "Mark the request as being processed by OpenAI"
      change transition_state(:openai_processing)
    end

    update :bulk_begin_processing do
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
    attribute :delivery_type, Batching.Types.RequestDeliveryType do
      allow_nil? false
      description "How to deliver the processed result"
      public? true
    end

    attribute :webhook_url, :string do
      description "Webhook URL (required if delivery_type is webhook)"
      public? true
    end

    attribute :rabbitmq_exchange, :string do
      description "RabbitMQ exchange"
      public? true
    end

    attribute :rabbitmq_queue, :string do
      description "RabbitMQ queue (required if delivery_type is rabbitmq)"
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
end
