defmodule Batcher.Batching.Request do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine]

  alias Batcher.Batching

  sqlite do
    table "requests"
    repo Batcher.Repo

    custom_indexes do
      # Ensure custom_id is unique within a batch
      index [:custom_id, :batch_id], unique: true
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
      transition :begin_processing, from: :pending, to: :processing
      transition :complete_processing, from: :processing, to: :processed
      transition :begin_delivery, from: :processed, to: :delivering
      transition :complete_delivery, from: :delivering, to: :delivered

      # Failure transitions
      transition :mark_failed, from: [:pending, :processing, :processed, :delivering], to: :failed
      transition :mark_expired, from: [:pending, :processing], to: :expired
      transition :cancel, from: :pending, to: :cancelled
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      description "Create a new request in a batch"
      accept [:batch_id, :custom_id, :url, :model]

      argument :request_payload, :map do
        description "The request payload as a map"
        allow_nil? false
      end

      argument :delivery, :map do
        description "How to deliver the processed result"
        allow_nil? false
      end

      change Batching.Changes.SetDeliveryConfig
      change Batching.Changes.SetPayload
      primary? true
    end

    # ============================================
    # Transition actions
    # ============================================

    update :begin_processing do
      require_atomic? false
      change transition_state(:processing)
    end

    update :complete_processing do
      require_atomic? false
      change transition_state(:processed)
    end

    update :begin_delivery do
      require_atomic? false
      change transition_state(:delivering)
    end

    update :complete_delivery do
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

  changes do
    change {Batching.Changes.CreateTransition,
            transition_resource: Batching.RequestTransition,
            parent_id_field: :request_id,
            state_attribute: :state},
           where: [changing(:state)]
  end

  attributes do
    integer_primary_key :id

    attribute :custom_id, :string do
      description "Custom identifier for the request (must be unique in it's batch)"
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      description "OpenAI Batch API endpoint (e.g., /v1/responses)"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "Model name (e.g., gpt-4o, text-embedding-3-large)"
      allow_nil? false
      public? true
    end

    attribute :request_payload, :string do
      description "Complete request payload as JSON object"
      allow_nil? false
      public? true
    end

    attribute :request_payload_size, :integer do
      description "Size of the request payload in bytes"
      allow_nil? false
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
    end

    has_many :transitions, Batching.RequestTransition do
      description "Audit trail of status transitions"
    end
  end
end
