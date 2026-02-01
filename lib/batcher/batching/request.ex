defmodule Batcher.Batching.Request do
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStateMachine, AshOban],
    notifiers: [Ash.Notifier.PubSub]

  require Ash.Query

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

      # Redeliver - allows redelivery from any state that has a response
      transition :retry_delivery,
        from: [:openai_processed, :delivered, :delivery_failed],
        to: :openai_processed

      transition :reset_to_pending, from: :openai_processing, to: :pending
      transition :bulk_reset_to_pending, from: :openai_processing, to: :pending

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

    read :search do
      description "Search for requests by custom_id or model"

      argument :query, :ci_string do
        description "Filter requests by custom_id or model"
        constraints allow_empty?: true
        default ""
      end

      argument :batch_id, :integer do
        description "Filter requests by batch ID"
      end

      argument :sort_input, :string do
        description "Sort field with optional - prefix for descending"
        default "-created_at"
      end

      filter expr(
               contains(custom_id, ^arg(:query)) or contains(model, ^arg(:query)) or
                 contains(url, ^arg(:query))
             )

      prepare fn query, _context ->
        sort_input = Ash.Query.get_argument(query, :sort_input)
        batch_id = Ash.Query.get_argument(query, :batch_id)

        query =
          query
          |> apply_sorting(sort_input)

        if batch_id do
          Ash.Query.filter(query, batch_id == ^batch_id)
        else
          query
        end
      end

      pagination offset?: true, default_limit: 15, countable: true
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

    update :reset_to_pending do
      description "Reset a request from openai_processing back to pending for reprocessing"
      require_atomic? false
      change transition_state(:pending)
    end

    update :bulk_reset_to_pending do
      description "Bulk reset requests from openai_processing back to pending"
      require_atomic? false
      change transition_state(:pending)
    end

    update :update_delivery_config do
      description "Update the delivery configuration for a request"
      accept [:delivery_config]
      require_atomic? false
      validate Batching.Validations.DeliveryConfig
    end

    update :retry_delivery do
      description "Retry delivery of a request that failed"
      require_atomic? false
      change transition_state(:openai_processed)
      change run_oban_trigger(:deliver)
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

    create_timestamp :created_at, public?: true
    update_timestamp :updated_at, public?: true
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

  defp apply_sorting(query, nil), do: Ash.Query.sort(query, created_at: :desc)

  defp apply_sorting(query, sort_by) when is_binary(sort_by) do
    case parse_sort_by(sort_by) do
      {field, direction} ->
        Ash.Query.sort(query, [{field, direction}])

      _ ->
        Ash.Query.sort(query, created_at: :desc)
    end
  end

  defp parse_sort_by("-created_at"), do: {:created_at, :desc}
  defp parse_sort_by("created_at"), do: {:created_at, :asc}
  defp parse_sort_by("-updated_at"), do: {:updated_at, :desc}
  defp parse_sort_by("updated_at"), do: {:updated_at, :asc}
  defp parse_sort_by("-state"), do: {:state, :desc}
  defp parse_sort_by("state"), do: {:state, :asc}
  defp parse_sort_by("-custom_id"), do: {:custom_id, :desc}
  defp parse_sort_by("custom_id"), do: {:custom_id, :asc}
  defp parse_sort_by("-model"), do: {:model, :desc}
  defp parse_sort_by("model"), do: {:model, :asc}
  defp parse_sort_by("-batch_id"), do: {:batch_id, :desc}
  defp parse_sort_by("batch_id"), do: {:batch_id, :asc}
  defp parse_sort_by(_), do: {:created_at, :desc}
end
