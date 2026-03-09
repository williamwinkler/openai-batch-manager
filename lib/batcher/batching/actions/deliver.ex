defmodule Batcher.Batching.Actions.Deliver do
  @moduledoc """
  Delivers the response_payload to the configured delivery destination.

  This action intentionally performs exactly one delivery attempt:
  - A single webhook or RabbitMQ delivery attempt is executed.
  - On success the request transitions to `:delivered`.
  - On failure the request transitions to `:delivery_failed`.

  All failures are recorded as delivery attempts on the request history.
  """
  require Logger
  require Ash.Query

  @default_delivery_receive_timeout 15_000
  @default_delivery_connect_timeout 10_000

  @doc false
  def run(input, _opts, _context) do
    request_id = Batcher.Batching.Utils.extract_subject_id(input)

    request =
      Batcher.Batching.Request
      |> Ash.Query.filter(id == ^request_id)
      |> Ash.read_one!()

    request_to_deliver =
      case request.state do
        :openai_processed -> begin_delivery(request)
        _ -> request
      end

    Logger.info("Delivering request #{request_to_deliver.id}")

    started_at = System.monotonic_time()

    result =
      case request_to_deliver.delivery_config["type"] do
        "rabbitmq" ->
          deliver_rabbitmq(request_to_deliver)

        "webhook" ->
          deliver_webhook(request_to_deliver)

        _ ->
          deliver_webhook(request_to_deliver)
      end

    emit_attempt_duration(result, request_to_deliver.delivery_config["type"], started_at)
    result
  end

  # --- Webhook delivery ---

  defp deliver_webhook(request) do
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
        case try_webhook_delivery(webhook_url, request) do
          :ok ->
            Logger.info("Webhook delivery succeeded for request #{request.id}")
            handle_delivery_success(request)

          {:error, outcome, error_msg} ->
            Logger.error("Webhook delivery failed for request #{request.id}: #{error_msg}")
            handle_delivery_failure(request, outcome, error_msg)
        end
    end
  end

  defp try_webhook_delivery(webhook_url, request) do
    case post_webhook(webhook_url, request) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      {:ok, _status, _headers, body} ->
        {:error, :http_status_not_2xx, encode_response_body(body)}

      {:error, reason} ->
        {:error, map_webhook_error(reason), format_error(reason)}
    end
  end

  # --- RabbitMQ delivery ---

  defp deliver_rabbitmq(request) do
    queue = request.delivery_config["rabbitmq_queue"]

    if not Batcher.RabbitMQ.Publisher.started?() do
      error_msg =
        "RabbitMQ is not configured. Set RABBITMQ_URL environment variable to enable RabbitMQ delivery."

      Logger.error("Webhook delivery failed for request #{request.id}: #{error_msg}")

      handle_delivery_failure(request, :connection_error, error_msg)
    else
      cond do
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
          case try_rabbitmq_delivery(queue, request) do
            :ok ->
              Logger.info("RabbitMQ delivery succeeded for request #{request.id}")
              handle_delivery_success(request)

            {:error, outcome, error_msg} ->
              Logger.error("RabbitMQ delivery failed for request #{request.id}: #{error_msg}")
              handle_delivery_failure(request, outcome, error_msg)
          end
      end
    end
  end

  defp try_rabbitmq_delivery(queue, request) do
    idempotency_key = idempotency_key(request.id)

    publish_opts = [
      message_id: idempotency_key,
      headers: [
        {"x-batcher-request-id", request.id},
        {"x-batcher-custom-id", request.custom_id},
        {"idempotency-key", idempotency_key}
      ]
    ]

    case Batcher.RabbitMQ.Publisher.publish("", queue, request.response_payload, publish_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, map_rabbitmq_error(reason), format_rabbitmq_error(reason)}
    end
  end

  # --- State transition helpers ---

  defp begin_delivery(request) do
    request
    |> Ash.Changeset.for_update(:begin_delivery)
    |> Ash.update!()
    |> Ash.load!(:batch)
  end

  defp handle_delivery_success(request) do
    request_after =
      request
      |> Ash.Changeset.for_update(:complete_delivery)
      |> Ash.Changeset.put_context(:delivery_attempt, %{outcome: :success})
      |> Ash.update!()

    {:ok, request_after}
  end

  defp handle_delivery_failure(request, outcome, error_msg) do
    request_after =
      request
      |> Ash.Changeset.for_update(:mark_delivery_failed)
      |> Ash.Changeset.put_context(:delivery_attempt, %{
        outcome: outcome,
        error_msg: error_msg
      })
      |> Ash.update!()

    {:ok, request_after}
  end

  # --- HTTP helpers ---

  defp post_webhook(url, request) do
    http_timeouts = Application.get_env(:batcher, :http_timeouts, [])

    receive_timeout =
      Keyword.get(http_timeouts, :receive_timeout, @default_delivery_receive_timeout)

    connect_timeout =
      Keyword.get(http_timeouts, :connect_timeout, @default_delivery_connect_timeout)

    idempotency_key = idempotency_key(request.id)

    case Req.post(url,
           json: request.response_payload,
           headers: [
             {"content-type", "application/json"},
             {"idempotency-key", idempotency_key},
             {"x-batcher-request-id", to_string(request.id)},
             {"x-batcher-custom-id", to_string(request.custom_id)}
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
        {:error, _} -> :failed
      end

    :telemetry.execute(
      [:batcher, :delivery, :attempt],
      %{duration: System.monotonic_time() - started_at},
      %{delivery_type: delivery_type, outcome: outcome}
    )
  end

  defp idempotency_key(request_id) do
    "batcher:req:#{request_id}"
  end
end
