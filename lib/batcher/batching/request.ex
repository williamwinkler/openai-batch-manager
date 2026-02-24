defmodule Batcher.Batching.Request do
  @moduledoc """
  Ash resource representing a single request in a batch.
  """
  use Ash.Resource,
    otp_app: :batcher,
    domain: Batcher.Batching,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshOban],
    notifiers: [Ash.Notifier.PubSub]

  require Ash.Query

  alias Batcher.Batching

  postgres do
    table "requests"
    repo Batcher.Repo

    custom_indexes do
      # Ensure custom_id is globally unique across all requests
      index [:custom_id], unique: true
      index [:state]
      index [:batch_id]
      index [:batch_id, :state]
      index [:created_at, :id], name: "requests_pagination_created_at_id_index"
      index [:updated_at]
      index [:batch_id, :created_at, :id], name: "requests_batch_pagination_created_at_id_index"
    end

    custom_statements do
      statement :requests_after_insert_update_batch_counters do
        up """
        CREATE OR REPLACE FUNCTION requests_after_insert_update_batch_counters_fn()
        RETURNS trigger AS $$
        BEGIN
          UPDATE batches
          SET
            request_count = request_count + 1,
            size_bytes = size_bytes + COALESCE(NEW.request_payload_size, 0),
            estimated_input_tokens_total = estimated_input_tokens_total + COALESCE(NEW.estimated_input_tokens, 0),
            estimated_request_input_tokens_total = estimated_request_input_tokens_total + COALESCE(NEW.estimated_request_input_tokens, 0)
          WHERE id = NEW.batch_id;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS requests_after_insert_update_batch_counters ON requests;
        CREATE TRIGGER requests_after_insert_update_batch_counters
        AFTER INSERT ON requests
        FOR EACH ROW
        EXECUTE FUNCTION requests_after_insert_update_batch_counters_fn();
        """

        down """
        DROP TRIGGER IF EXISTS requests_after_insert_update_batch_counters ON requests;
        DROP FUNCTION IF EXISTS requests_after_insert_update_batch_counters_fn();
        """
      end

      statement :requests_after_delete_update_batch_counters do
        up """
        CREATE OR REPLACE FUNCTION requests_after_delete_update_batch_counters_fn()
        RETURNS trigger AS $$
        BEGIN
          UPDATE batches
          SET
            request_count = request_count - 1,
            size_bytes = size_bytes - COALESCE(OLD.request_payload_size, 0),
            estimated_input_tokens_total = estimated_input_tokens_total - COALESCE(OLD.estimated_input_tokens, 0),
            estimated_request_input_tokens_total = estimated_request_input_tokens_total - COALESCE(OLD.estimated_request_input_tokens, 0)
          WHERE id = OLD.batch_id;

          RETURN OLD;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS requests_after_delete_update_batch_counters ON requests;
        CREATE TRIGGER requests_after_delete_update_batch_counters
        AFTER DELETE ON requests
        FOR EACH ROW
        EXECUTE FUNCTION requests_after_delete_update_batch_counters_fn();
        """

        down """
        DROP TRIGGER IF EXISTS requests_after_delete_update_batch_counters ON requests;
        DROP FUNCTION IF EXISTS requests_after_delete_update_batch_counters_fn();
        """
      end

      statement :requests_after_update_same_batch_update_counters do
        up """
        CREATE OR REPLACE FUNCTION requests_after_update_same_batch_update_counters_fn()
        RETURNS trigger AS $$
        BEGIN
          IF OLD.batch_id = NEW.batch_id THEN
            UPDATE batches
            SET
              size_bytes = size_bytes + (COALESCE(NEW.request_payload_size, 0) - COALESCE(OLD.request_payload_size, 0)),
              estimated_input_tokens_total = estimated_input_tokens_total + (COALESCE(NEW.estimated_input_tokens, 0) - COALESCE(OLD.estimated_input_tokens, 0)),
              estimated_request_input_tokens_total = estimated_request_input_tokens_total + (COALESCE(NEW.estimated_request_input_tokens, 0) - COALESCE(OLD.estimated_request_input_tokens, 0))
            WHERE id = NEW.batch_id;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS requests_after_update_same_batch_update_counters ON requests;
        CREATE TRIGGER requests_after_update_same_batch_update_counters
        AFTER UPDATE OF request_payload_size, estimated_input_tokens, estimated_request_input_tokens ON requests
        FOR EACH ROW
        EXECUTE FUNCTION requests_after_update_same_batch_update_counters_fn();
        """

        down """
        DROP TRIGGER IF EXISTS requests_after_update_same_batch_update_counters ON requests;
        DROP FUNCTION IF EXISTS requests_after_update_same_batch_update_counters_fn();
        """
      end

      statement :requests_after_update_move_batch_update_counters do
        up """
        CREATE OR REPLACE FUNCTION requests_after_update_move_batch_update_counters_fn()
        RETURNS trigger AS $$
        BEGIN
          IF OLD.batch_id != NEW.batch_id THEN
            UPDATE batches
            SET
              request_count = request_count - 1,
              size_bytes = size_bytes - COALESCE(OLD.request_payload_size, 0),
              estimated_input_tokens_total = estimated_input_tokens_total - COALESCE(OLD.estimated_input_tokens, 0),
              estimated_request_input_tokens_total = estimated_request_input_tokens_total - COALESCE(OLD.estimated_request_input_tokens, 0)
            WHERE id = OLD.batch_id;

            UPDATE batches
            SET
              request_count = request_count + 1,
              size_bytes = size_bytes + COALESCE(NEW.request_payload_size, 0),
              estimated_input_tokens_total = estimated_input_tokens_total + COALESCE(NEW.estimated_input_tokens, 0),
              estimated_request_input_tokens_total = estimated_request_input_tokens_total + COALESCE(NEW.estimated_request_input_tokens, 0)
            WHERE id = NEW.batch_id;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS requests_after_update_move_batch_update_counters ON requests;
        CREATE TRIGGER requests_after_update_move_batch_update_counters
        AFTER UPDATE OF batch_id, request_payload_size, estimated_input_tokens, estimated_request_input_tokens ON requests
        FOR EACH ROW
        EXECUTE FUNCTION requests_after_update_move_batch_update_counters_fn();
        """

        down """
        DROP TRIGGER IF EXISTS requests_after_update_move_batch_update_counters ON requests;
        DROP FUNCTION IF EXISTS requests_after_update_move_batch_update_counters_fn();
        """
      end

      statement :request_delivery_attempts_after_insert_update_request_attempt_count do
        up """
        CREATE OR REPLACE FUNCTION request_delivery_attempts_after_insert_update_request_attempt_count_fn()
        RETURNS trigger AS $$
        BEGIN
          UPDATE requests
          SET delivery_attempt_count = delivery_attempt_count + 1
          WHERE id = NEW.request_id;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS request_delivery_attempts_after_insert_update_request_attempt_count ON request_delivery_attempts;
        CREATE TRIGGER request_delivery_attempts_after_insert_update_request_attempt_count
        AFTER INSERT ON request_delivery_attempts
        FOR EACH ROW
        EXECUTE FUNCTION request_delivery_attempts_after_insert_update_request_attempt_count_fn();
        """

        down """
        DROP TRIGGER IF EXISTS request_delivery_attempts_after_insert_update_request_attempt_count ON request_delivery_attempts;
        DROP FUNCTION IF EXISTS request_delivery_attempts_after_insert_update_request_attempt_count_fn();
        """
      end

      statement :ensure_pg_trgm_extension do
        up "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
        down "SELECT 1;"
      end

      statement :requests_custom_id_trgm_gin_index do
        up """
        CREATE INDEX IF NOT EXISTS requests_custom_id_trgm_gin_index
        ON requests USING gin (custom_id gin_trgm_ops);
        """

        down "DROP INDEX IF EXISTS requests_custom_id_trgm_gin_index;"
      end
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

      # Safety net for Oban on_error — transitions to delivery_failed if the
      # deliver action crashes unexpectedly on the final Oban attempt
      transition :handle_delivery_error, from: :delivering, to: :delivery_failed

      # Redeliver - allows redelivery from any state that has a response
      transition :retry_delivery,
        from: [:openai_processed, :delivered, :delivery_failed],
        to: :openai_processed

      transition :reset_to_pending, from: [:openai_processing, :failed], to: :pending
      transition :bulk_reset_to_pending, from: :openai_processing, to: :pending

      transition :restart_to_pending,
        from: [
          :openai_processing,
          :openai_processed,
          :delivering,
          :delivered,
          :failed,
          :delivery_failed,
          :expired,
          :cancelled
        ],
        to: :pending

      transition :mark_expired, from: [:pending, :openai_processing], to: :expired

      transition :cancel,
        from: [:pending, :openai_processing, :openai_processed, :delivering],
        to: :cancelled
    end
  end

  oban do
    triggers do
      trigger :deliver do
        action :deliver
        where expr(state == :openai_processed)
        scheduler_cron "* * * * *"
        queue :delivery
        max_attempts 3
        backoff 10
        on_error :handle_delivery_error
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

    read :list_by_custom_id do
      description "List requests by custom ID across all batches"
      argument :custom_id, :string, allow_nil?: false
      filter expr(custom_id == ^arg(:custom_id))

      prepare fn query, _ ->
        Ash.Query.sort(query, created_at: :desc)
      end
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

      argument :state_filter, Batching.Types.RequestStatus do
        description "Filter requests by an exact state"
      end

      argument :sort_input, :string do
        description "Sort field with optional - prefix for descending"
        default "-created_at"
      end

      prepare fn query, _context ->
        sort_input = Ash.Query.get_argument(query, :sort_input)

        query =
          query
          |> apply_query_filter()
          |> apply_sorting(sort_input)
          |> apply_batch_filter()
          |> apply_state_filter()

        query
      end

      pagination keyset?: true, default_limit: 25, countable: true
    end

    read :count_for_search do
      description "Count requests matching the search filters"

      argument :query, :ci_string do
        description "Filter requests by custom_id or model"
        constraints allow_empty?: true
        default ""
      end

      argument :batch_id, :integer do
        description "Filter requests by batch ID"
      end

      argument :state_filter, Batching.Types.RequestStatus do
        description "Filter requests by an exact state"
      end

      prepare fn query, _context ->
        query
        |> apply_query_filter()
        |> apply_batch_filter()
        |> apply_state_filter()
      end

      pagination offset?: true, countable: true
    end

    update :begin_processing do
      description "Mark the request as being processed by OpenAI"
      require_atomic? false
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

    update :handle_delivery_error do
      description "Safety net for Oban on_error — transitions to delivery_failed if the deliver action crashes on the final attempt"
      require_atomic? false
      argument :error, :string, allow_nil?: true
      change transition_state(:delivery_failed)
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

    update :restart_to_pending do
      description "Reset a request to pending state for batch restart"
      require_atomic? false
      accept [:error_msg, :response_payload]
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
      validate Batcher.Batching.Validations.RabbitmqConnectedForRetryDelivery
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

    publish_all :update, ["state_changed"],
      filter: fn notification ->
        Ash.Changeset.changing_attribute?(notification.changeset, :state)
      end

    publish_all :update, ["state_changed", :id],
      filter: fn notification ->
        Ash.Changeset.changing_attribute?(notification.changeset, :state)
      end
  end

  attributes do
    integer_primary_key :id

    attribute :custom_id, :string do
      description "Custom identifier for the request (must be globally unique)"
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

    attribute :estimated_input_tokens, :integer do
      description "Estimated input tokens used for queue-capacity admission"
      allow_nil? false
      default 0
      public? true
    end

    attribute :estimated_request_input_tokens, :integer do
      description "Estimated request input tokens for endpoint-aware display"
      allow_nil? false
      default 0
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

    attribute :delivery_attempt_count, :integer do
      description "Number of delivery attempts recorded for this request"
      allow_nil? false
      default 0
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

  defp apply_sorting(query, nil), do: Ash.Query.sort(query, created_at: :desc, id: :desc)

  defp apply_sorting(query, sort_by) when is_binary(sort_by) do
    case parse_sort_by(sort_by) do
      {field, direction} ->
        Ash.Query.sort(query, [{field, direction}, {:id, direction}])

      _ ->
        Ash.Query.sort(query, created_at: :desc, id: :desc)
    end
  end

  defp apply_batch_filter(query) do
    batch_id = Ash.Query.get_argument(query, :batch_id)

    if batch_id do
      Ash.Query.filter(query, batch_id == ^batch_id)
    else
      query
    end
  end

  defp apply_state_filter(query) do
    state_filter = Ash.Query.get_argument(query, :state_filter)

    if state_filter do
      Ash.Query.filter(query, state == ^state_filter)
    else
      query
    end
  end

  defp apply_query_filter(query) do
    query_value = query |> Ash.Query.get_argument(:query) |> to_string() |> String.trim()

    if query_value == "" do
      query
    else
      Ash.Query.filter(
        query,
        contains(custom_id, ^query_value) or contains(model, ^query_value) or
          contains(url, ^query_value)
      )
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
