defmodule Batcher.Batching.Actions.Deliver do
  @moduledoc """
  Delivers the response_payload to the configured webhook_url or RabbitMQ queue.

  Uses Oban's retry mechanism for backoff between attempts. The request stays
  in :delivering state during all retry attempts — no premature batch completion.

  On intermediate failure: records a RequestDeliveryAttempt and returns
  `{:error, ...}` which causes `Ash.run_action!` (in the AshOban worker)
  to raise, triggering an Oban retry with backoff.

  On final failure (delivery_attempt_count >= max_attempts): transitions the
  request to :delivery_failed and returns `{:ok, ...}` so Oban considers
  the job complete.

  Validation errors (missing webhook_url, missing response_payload, etc.)
  are never retried — they return immediately.

  For webhook delivery:
  - POSTs response_payload to webhook_url
  - Records delivery attempt (success or failure)
  - On success: transitions request to :delivered
  - On failure: transitions request to :delivery_failed (not :failed, which is for OpenAI errors)
  - Error details are stored on delivery_attempt only (not on request.error_msg)

  For RabbitMQ delivery:
  - Publishes response_payload to RabbitMQ queue
  - Records delivery attempt (success or failure)
  - On success: transitions request to :delivered
  - On failure: transitions request to :delivery_failed (not :failed, which is for OpenAI errors)
  - Error details are stored on delivery_attempt only (not on request.error_msg)
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching
  alias Batcher.Batching.Utils

  @default_max_attempts 3

  @doc false
  def run(input, _opts, _context) do
    request_id = Utils.extract_subject_id(input)

    request =
      Batching.Request
      |> Ash.Query.filter(id == ^request_id)
      |> Ash.read_one!()
      |> Ash.load!([:batch])

    batch = request.batch

    if batch.state != :delivering do
      Logger.debug(
        "Skipping delivery for request #{request.id}; batch #{batch.id} is in state #{batch.state}"
      )

      {:ok, request}
    else
      # On first attempt: openai_processed → delivering
      # On Oban retry: already in delivering, skip transition
      request_updated =
        case request.state do
          :openai_processed -> begin_delivery(request)
          :delivering -> request
        end

      # Determine attempt number from persisted request counter.
      current_attempt = (request_updated.delivery_attempt_count || 0) + 1
      max = max_attempts()
      started_at = System.monotonic_time()

      Logger.info("Delivering request #{request_updated.id} (attempt #{current_attempt}/#{max})")

      if current_attempt == 1 and request_updated.updated_at do
        enqueue_to_start_ms =
          DateTime.diff(DateTime.utc_now(), request_updated.updated_at, :millisecond)

        :telemetry.execute(
          [:batcher, :delivery, :enqueue_to_start],
          %{
            duration: System.convert_time_unit(max(enqueue_to_start_ms, 0), :millisecond, :native)
          },
          %{request_id: request_updated.id}
        )
      end

      if current_attempt > 1 do
        :telemetry.execute(
          [:batcher, :delivery, :retry],
          %{count: 1},
          %{request_id: request_updated.id, attempt: current_attempt}
        )
      end

      result =
        case request_updated.delivery_config["type"] do
          "rabbitmq" ->
            deliver_rabbitmq(request_updated, batch, current_attempt, max)

          "webhook" ->
            deliver_webhook(request_updated, batch, current_attempt, max)
        end

      emit_attempt_duration(result, request_updated.delivery_config["type"], started_at)
      result
    end
  end

  # --- Webhook delivery ---

  defp deliver_webhook(request, batch, current_attempt, max) do
    webhook_url = request.delivery_config["webhook_url"]

    cond do
      is_nil(webhook_url) ->
        validation_error(
          :delivery_config,
          "webhook_url is required for webhook delivery",
          request.id
        )

      is_nil(request.response_payload) ->
        validation_error(
          :response_payload,
          "response_payload is required for delivery",
          request.id
        )

      true ->
        case try_webhook_delivery(webhook_url, request, current_attempt) do
          :ok ->
            Logger.info("Delivery successful for request #{request.id}")
            handle_delivery_success(request, batch, current_attempt)

          {:error, outcome, error_msg} ->
            handle_attempt_failure(request, batch, outcome, error_msg, current_attempt, max)
        end
    end
  end

  defp try_webhook_delivery(webhook_url, request, current_attempt) do
    case post_webhook(webhook_url, request, current_attempt) do
      {:ok, status, _headers, _body} when status >= 200 and status < 300 ->
        :ok

      {:ok, _status, _headers, body} ->
        {:error, :http_status_not_2xx, encode_response_body(body)}

      {:error, reason} ->
        {:error, map_webhook_error(reason), format_error(reason)}
    end
  end

  # --- RabbitMQ delivery ---

  defp deliver_rabbitmq(request, batch, current_attempt, max) do
    queue = request.delivery_config["rabbitmq_queue"]

    # Check if RabbitMQ Publisher is running BEFORE delivery attempt
    rabbitmq_configured? = Batcher.RabbitMQ.Publisher.started?()

    cond do
      not rabbitmq_configured? ->
        # Non-retryable configuration error — go straight to delivery_failed
        error_msg =
          "RabbitMQ is not configured. Set RABBITMQ_URL environment variable to enable RabbitMQ delivery."

        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")
        handle_delivery_failure(request, batch, :rabbitmq_not_configured, error_msg)

      is_nil(queue) or queue == "" ->
        validation_error(
          :delivery_config,
          "rabbitmq_queue is required for RabbitMQ delivery",
          request.id
        )

      is_nil(request.response_payload) ->
        validation_error(
          :response_payload,
          "response_payload is required for delivery",
          request.id
        )

      true ->
        case try_rabbitmq_delivery(queue, request, current_attempt) do
          :ok ->
            Logger.info("Delivery successful for request #{request.id}")
            handle_delivery_success(request, batch, current_attempt)

          {:error, outcome, error_msg} ->
            handle_attempt_failure(request, batch, outcome, error_msg, current_attempt, max)
        end
    end
  end

  defp try_rabbitmq_delivery(queue, request, current_attempt) do
    idempotency_key = idempotency_key(request.id, current_attempt)

    publish_opts = [
      message_id: idempotency_key,
      headers: [
        {"x-batcher-request-id", request.id},
        {"x-batcher-custom-id", request.custom_id},
        {"x-batcher-attempt", current_attempt},
        {"idempotency-key", idempotency_key}
      ]
    ]

    case Batcher.RabbitMQ.Publisher.publish(
           "",
           queue,
           request.response_payload,
           publish_opts
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, map_rabbitmq_error(reason), format_rabbitmq_error(reason)}
    end
  end

  # --- Attempt failure handling ---

  # Final attempt — transition to delivery_failed and return ok (job complete)
  defp handle_attempt_failure(request, batch, outcome, error_msg, current_attempt, max)
       when current_attempt >= max do
    Logger.error(
      "Delivery failed after #{max} attempt(s) for request #{request.id}: #{error_msg}"
    )

    handle_delivery_failure(request, batch, outcome, error_msg)
  end

  # Intermediate attempt — record attempt and return error to trigger Oban retry
  defp handle_attempt_failure(request, _batch, outcome, error_msg, current_attempt, max) do
    Logger.warning(
      "Delivery attempt #{current_attempt}/#{max} failed for request #{request.id}: #{error_msg}, will retry..."
    )

    record_intermediate_attempt(request, outcome, error_msg, current_attempt)
    {:error, "Delivery attempt #{current_attempt}/#{max} failed: #{error_msg}"}
  end

  # --- State transition helpers ---

  defp begin_delivery(request) do
    request
    |> Ash.Changeset.for_update(:begin_delivery)
    |> Ash.update!()
    |> Ash.load!(:batch)
  end

  defp handle_delivery_success(request, _batch, current_attempt) do
    request_after =
      request
      |> Ash.Changeset.for_update(:complete_delivery)
      |> Ash.Changeset.put_context(:delivery_attempt, %{
        outcome: :success,
        attempt_number: current_attempt
      })
      |> Ash.update!()

    {:ok, request_after}
  end

  defp handle_delivery_failure(request, _batch, outcome, error_msg) do
    # Mark request as delivery_failed (not :failed) because this is a delivery error,
    # not an OpenAI processing error. The error is recorded on the delivery_attempt.
    request_after =
      request
      |> Ash.Changeset.for_update(:mark_delivery_failed, %{})
      |> Ash.Changeset.put_context(:delivery_attempt, %{
        outcome: outcome,
        error_msg: error_msg,
        attempt_number: current_attempt(request)
      })
      |> Ash.update!()

    {:ok, request_after}
  end

  defp record_intermediate_attempt(request, outcome, error_msg, current_attempt) do
    Ash.create!(Batching.RequestDeliveryAttempt, %{
      request_id: request.id,
      attempt_number: current_attempt,
      delivery_config: request.delivery_config,
      outcome: outcome,
      error_msg: error_msg
    })
  end

  # --- HTTP helpers ---

  defp post_webhook(url, request, current_attempt) do
    # Use configurable timeout - low for tests, reasonable for production
    http_timeouts = Application.get_env(:batcher, :http_timeouts, [])
    receive_timeout = Keyword.get(http_timeouts, :receive_timeout, 30_000)
    connect_timeout = Keyword.get(http_timeouts, :connect_timeout, 10_000)
    idempotency_key = idempotency_key(request.id, current_attempt)

    case Req.post(url,
           json: request.response_payload,
           headers: [
             {"content-type", "application/json"},
             {"idempotency-key", idempotency_key},
             {"x-batcher-request-id", to_string(request.id)},
             {"x-batcher-custom-id", to_string(request.custom_id)},
             {"x-batcher-attempt", Integer.to_string(current_attempt)}
           ],
           retry: false,
           receive_timeout: receive_timeout,
           connect_options: [timeout: connect_timeout]
         ) do
      {:ok, response} ->
        {:ok, response.status, response.headers, response.body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Validation error helper ---

  defp validation_error(field, error_msg, request_id) do
    Logger.error("Delivery failed for request #{request_id}: #{error_msg}")

    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         %Ash.Error.Changes.InvalidAttribute{
           field: field,
           message: error_msg
         }
       ]
     )}
  end

  # --- Config ---

  defp max_attempts do
    if Application.get_env(:batcher, :disable_delivery_retry, false) do
      1
    else
      Application.get_env(:batcher, :delivery_max_attempts, @default_max_attempts)
    end
  end

  # --- Error mapping and formatting ---

  defp map_rabbitmq_error(reason) do
    case reason do
      :queue_not_found -> :queue_not_found
      :exchange_not_found -> :exchange_not_found
      :not_connected -> :connection_error
      :timeout -> :timeout
      _ -> :other
    end
  end

  defp map_webhook_error(reason) do
    case reason do
      %{__struct__: %{reason: :timeout}} -> :timeout
      %{__struct__: %{reason: :econnrefused}} -> :connection_error
      %{__struct__: %{reason: :nxdomain}} -> :connection_error
      %{reason: :timeout} -> :timeout
      %{reason: :econnrefused} -> :connection_error
      %{reason: :nxdomain} -> :connection_error
      :timeout -> :timeout
      :econnrefused -> :connection_error
      :nxdomain -> :connection_error
      _ -> :connection_error
    end
  end

  defp format_rabbitmq_error(reason) do
    case reason do
      :queue_not_found -> "Queue not found"
      :exchange_not_found -> "Exchange not found"
      :not_connected -> "Not connected to RabbitMQ"
      :timeout -> "Publish confirmation timeout"
      :nack -> "Message was nacked by broker"
      other -> "RabbitMQ error: #{inspect(other)}"
    end
  end

  defp encode_response_body(body) when is_binary(body) do
    # Try to parse as JSON, if it fails, return as-is
    case JSON.decode(body) do
      {:ok, decoded} -> JSON.encode!(decoded)
      {:error, _} -> body
    end
  end

  defp encode_response_body(body) when is_map(body) do
    JSON.encode!(body)
  end

  defp encode_response_body(body) do
    to_string(body)
  end

  defp format_error(%{__struct__: _} = exception) do
    Exception.message(exception)
  end

  defp format_error(reason) do
    inspect(reason)
  end

  defp emit_attempt_duration(result, delivery_type, started_at) do
    outcome =
      case result do
        {:ok, %{state: :delivered}} -> :delivered
        {:ok, %{state: :delivery_failed}} -> :delivery_failed
        {:ok, _} -> :ok
        {:error, _} -> :retryable_error
      end

    :telemetry.execute(
      [:batcher, :delivery, :attempt],
      %{duration: System.monotonic_time() - started_at},
      %{delivery_type: delivery_type, outcome: outcome}
    )
  end

  defp current_attempt(request) do
    (request.delivery_attempt_count || 0) + 1
  end

  defp idempotency_key(request_id, attempt_number) do
    "batcher:req:#{request_id}:attempt:#{attempt_number}"
  end
end
