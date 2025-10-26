defmodule Batcher.Batching.Prompt do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine]

  alias Batcher.Batching

  sqlite do
    table "prompts"
    repo Batcher.Repo

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
      accept [:batch_id, :custom_id, :delivery_type]

      argument :tag, :string, allow_nil?: true
      argument :webhook_url, :string, allow_nil?: true
      argument :rabbitmq_queue, :string, allow_nil?: true
      argument :provider, Batching.Types.Provider, allow_nil?: false
      argument :model, :string, allow_nil?: false

      validate Batching.Validations.ValidateDeliveryConfig
      validate Batching.Validations.ValidatePromptMatchesBatch

      change set_attribute(:tag, arg(:tag))
      change set_attribute(:webhook_url, arg(:webhook_url))
      change set_attribute(:rabbitmq_queue, arg(:rabbitmq_queue))
    end

    # Transition actions
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

    attribute :custom_id, :string do
      description "User defined id for the prompt"
      public? true
      allow_nil? false
    end

    attribute :tag, :string do
      description "User defined prompt for prompt management"
      public? true
    end

    attribute :state, Batching.Types.PromptStatus do
      description "Current state of the prompt"
      allow_nil? false
      default :pending
      public? true
    end

    attribute :error_msg, :string do
      description "Error message if prompt processing or delivery failed"
    end

    attribute :delivery_type, Batching.Types.PromptDeliveryType do
      allow_nil? false
      description "How to deliver the result of the processed prompt"
      public? true
    end

    attribute :rabbitmq_queue, :string do
      description "RabbitMQ queue name (required if delivery_type is rabbitmq)"
      public? true
    end

    attribute :webhook_url, :string do
      description "Webhook URL for delivery (required if delivery_type is webhook)"
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
