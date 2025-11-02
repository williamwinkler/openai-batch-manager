defmodule Batcher.Batching.Prompt do
  @moduledoc """
  Represents a prompt to be processed via OpenAI Batch API.

  Prompts are automatically assigned to batches based on their endpoint and model.
  Clients never specify batch_id - it's assigned by the BatchBuilder GenServer.

  The prompt stores:
  - Metadata: batch_id, custom_id, endpoint, model, delivery config, state
  - Request payload: Full request body as JSON for JSONL generation
  """
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource, AshStateMachine]

  alias Batcher.Batching

  sqlite do
    table "prompts"
    repo Batcher.Repo

    custom_indexes do
      index [:custom_id], unique: true
    end

    references do
      reference :batch, on_delete: :delete
    end
  end

  json_api do
    type "prompt"
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

    # ============================================
    # /v1/responses endpoint
    # ============================================

    create :create_for_responses do
      description "Submit a prompt for /v1/responses endpoint"
      accept [:custom_id, :tag]

      # Request parameters (typed and validated)
      argument :model, :string, allow_nil?: false
      argument :input, Batching.Types.ResponsesInputType, allow_nil?: false
      argument :text, Batching.Resources.TextFormat, allow_nil?: true
      argument :instructions, :string, allow_nil?: true
      argument :temperature, :float, allow_nil?: true
      argument :max_output_tokens, :integer, allow_nil?: true
      argument :top_p, :float, allow_nil?: true
      argument :store, :boolean, default: true
      argument :additional_params, :map, allow_nil?: true

      # Delivery configuration
      argument :delivery_type, Batching.Types.PromptDeliveryType, allow_nil?: false
      argument :webhook_url, :string, allow_nil?: true
      argument :rabbitmq_queue, :string, allow_nil?: true

      # Validations
      validate Batching.Validations.ValidateDeliveryConfig

      validate compare(:temperature, greater_than_or_equal_to: 0),
        where: present(:temperature)

      validate compare(:temperature, less_than_or_equal_to: 2), where: present(:temperature)
      validate compare(:top_p, greater_than_or_equal_to: 0), where: present(:top_p)
      validate compare(:top_p, less_than_or_equal_to: 1), where: present(:top_p)

      validate compare(:max_output_tokens, greater_than: 0),
        where: present(:max_output_tokens)

      # Build request payload and assign to batch
      change Batching.Changes.BuildResponsesPayload
      change Batching.Changes.AssignToBatch

      # Set delivery fields
      change set_attribute(:delivery_type, arg(:delivery_type))
      change set_attribute(:webhook_url, arg(:webhook_url))
      change set_attribute(:rabbitmq_queue, arg(:rabbitmq_queue))
    end

    # ============================================
    # Internal action (called by BatchBuilder)
    # ============================================

    create :create_internal do
      description "Internal: Create prompt with batch_id assigned by BatchBuilder"

      accept [
        :batch_id,
        :endpoint,
        :model,
        :custom_id,
        :request_payload,
        :delivery_type,
        :webhook_url,
        :rabbitmq_queue,
        :tag
      ]

      validate Batching.Validations.ValidateDeliveryConfig
      validate Batching.Validations.ValidateEndpointSupported
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
            transition_resource: Batching.PromptTransition,
            parent_id_field: :prompt_id,
            state_attribute: :state},
           where: [changing(:state)]
  end

  attributes do
    integer_primary_key :id

    # Batch relationship
    attribute :batch_id, :integer do
      allow_nil? false
      public? true
    end

    # Endpoint identification
    attribute :endpoint, :string do
      description "OpenAI Batch API endpoint (e.g., /v1/responses)"
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      description "Model name (e.g., gpt-4o, text-embedding-3-large)"
      allow_nil? false
      public? true
    end

    attribute :custom_id, :string do
      description "Globally unique identifier for this prompt"
      allow_nil? false
      public? true
    end

    # Full request payload (endpoint-specific)
    attribute :request_payload, :map do
      description "Complete request body for the OpenAI endpoint"
      allow_nil? false
      public? true
    end

    # Optional tag for client-side organization
    attribute :tag, :string do
      description "Optional tag for grouping/filtering prompts"
      public? true
    end

    # State machine
    attribute :state, Batching.Types.PromptStatus do
      description "Current state of the prompt"
      allow_nil? false
      default :pending
      public? true
    end

    attribute :error_msg, :string do
      description "Error message if processing or delivery failed"
    end

    # Delivery configuration
    attribute :delivery_type, Batching.Types.PromptDeliveryType do
      allow_nil? false
      description "How to deliver the processed result"
      public? true
    end

    attribute :webhook_url, :string do
      description "Webhook URL (required if delivery_type is webhook)"
      public? true
    end

    attribute :rabbitmq_queue, :string do
      description "RabbitMQ queue (required if delivery_type is rabbitmq)"
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :batch, Batching.Batch do
      description "The batch this prompt belongs to"
      allow_nil? false
      public? true
    end

    has_many :transitions, Batching.PromptTransition do
      description "Audit trail of status transitions"
    end
  end
end
