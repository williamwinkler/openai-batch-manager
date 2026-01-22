defmodule Batcher.Batching.Actions.Deliver do
  @moduledoc """
  Delivers the response_payload to the configured webhook_url or RabbitMQ queue.

  For webhook delivery:
  - POSTs response_payload to webhook_url
  - Records delivery attempt (success or failure)
  - On success: transitions request to :delivered
  - On failure: transitions request to :delivery_failed (not :failed, which is for OpenAI errors)
  - Error details are stored on delivery_attempt only (not on request.error_msg)

  For RabbitMQ delivery:
  - Publishes response_payload to RabbitMQ queue/exchange
  - Records delivery attempt (success or failure)
  - On success: transitions request to :delivered
  - On failure: transitions request to :delivery_failed (not :failed, which is for OpenAI errors)
  - Error details are stored on delivery_attempt only (not on request.error_msg)
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching
  alias Batcher.Batching.Utils

  def run(input, _opts, _context) do
    request_id = Utils.extract_subject_id(input)

    request =
      Batching.Request
      |> Ash.Query.filter(id == ^request_id)
      |> Ash.read_one!()
      |> Ash.load!([:batch])

    # Load delivery attempt count for logging
    request = Ash.load!(request, :delivery_attempt_count)
    attempt_number = request.delivery_attempt_count + 1
    Logger.info("Delivering request #{request.id} (attempt #{attempt_number})")

    # Check delivery type
    case request.delivery_config["type"] do
      "rabbitmq" ->
        deliver_rabbitmq(request)

      "webhook" ->
        deliver_webhook(request)
    end
  end

  defp deliver_webhook(request) do
    webhook_url = request.delivery_config["webhook_url"]

    # Validate required fields
    cond do
      is_nil(webhook_url) ->
        error_msg = "webhook_url is required for webhook delivery"
        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :delivery_config,
               message: error_msg
             }
           ]
         )}

      is_nil(request.response_payload) ->
        error_msg = "response_payload is required for delivery"
        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :response_payload,
               message: error_msg
             }
           ]
         )}

      true ->
        perform_webhook_delivery(request, webhook_url)
    end
  end

  defp deliver_rabbitmq(request) do
    # Support both old format (exchange/routing_key/queue) and new format (rabbitmq_exchange/rabbitmq_queue/rabbitmq_routing_key)
    exchange =
      request.delivery_config["rabbitmq_exchange"] ||
        request.delivery_config["exchange"] || ""

    # Priority: rabbitmq_routing_key (new) > routing_key (legacy) > rabbitmq_queue > queue (legacy)
    routing_key =
      request.delivery_config["rabbitmq_routing_key"] ||
        request.delivery_config["routing_key"] ||
        request.delivery_config["rabbitmq_queue"] ||
        request.delivery_config["queue"]

    # Validate required fields
    cond do
      is_nil(routing_key) ->
        error_msg = "queue or routing_key is required for RabbitMQ delivery"
        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :delivery_config,
               message: error_msg
             }
           ]
         )}

      is_nil(request.response_payload) ->
        error_msg = "response_payload is required for delivery"
        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :response_payload,
               message: error_msg
             }
           ]
         )}

      true ->
        perform_rabbitmq_delivery(request, exchange, routing_key)
    end
  end

  defp perform_rabbitmq_delivery(request, exchange, routing_key) do
    # Transition to delivering state
    request_updated =
      request
      |> Ash.Changeset.for_update(:begin_delivery)
      |> Ash.update!()
      |> Ash.load!(:batch)

    # Check if batch needs to transition to :delivering
    batch = request_updated.batch

    if batch.state == :ready_to_deliver do
      batch
      |> Ash.Changeset.for_update(:start_delivering)
      |> Ash.update!()
    end

    # Perform RabbitMQ publish
    case Batcher.RabbitMQ.Publisher.publish(
           exchange,
           routing_key,
           request_updated.response_payload
         ) do
      :ok ->
        # Success
        Logger.info(
          "RabbitMQ delivery successful for request #{request_updated.custom_id} (exchange=#{exchange} routing_key=#{routing_key})"
        )

        request_after =
          request_updated
          |> Ash.Changeset.for_update(:complete_delivery)
          |> Ash.Changeset.put_context(:delivery_attempt, %{outcome: :success})
          |> Ash.update!()

        handle_delivery_result({:ok, request_after}, batch)

      {:error, reason} ->
        # RabbitMQ error
        outcome = map_rabbitmq_error(reason)
        error_msg = format_rabbitmq_error(reason)

        Logger.warning(
          "RabbitMQ delivery failed for request #{request_updated.id} (exchange=#{exchange} routing_key=#{routing_key}): #{error_msg}"
        )

        handle_delivery_failure(request_updated, batch, outcome, error_msg)
    end
  end

  defp perform_webhook_delivery(request, webhook_url) do
    # Transition to delivering state
    request_updated =
      request
      |> Ash.Changeset.for_update(:begin_delivery)
      |> Ash.update!()
      |> Ash.load!(:batch)

    # Check if batch needs to transition to :delivering
    batch = request_updated.batch

    if batch.state == :ready_to_deliver do
      batch
      |> Ash.Changeset.for_update(:start_delivering)
      |> Ash.update!()
    end

    # Perform webhook POST
    case post_webhook(webhook_url, request_updated.response_payload) do
      {:ok, status, _headers, _body} when status >= 200 and status < 300 ->
        # Success
        Logger.info(
          "Webhook delivery successful for request #{request_updated.custom_id} (status: #{status})"
        )

        request_after =
          request_updated
          |> Ash.Changeset.for_update(:complete_delivery)
          |> Ash.Changeset.put_context(:delivery_attempt, %{
            outcome: :success,
            error_msg: nil
          })
          |> Ash.update!()

        handle_delivery_result({:ok, request_after}, batch)

      {:ok, status, _headers, body} ->
        # HTTP error (non-2xx)
        error_msg = encode_response_body(body)

        Logger.warning(
          "Webhook delivery failed for request #{request_updated.id} (status: #{status}): #{error_msg}"
        )

        handle_delivery_failure(request_updated, batch, :http_status_not_2xx, error_msg)

      {:error, reason} ->
        # Network error
        outcome = map_webhook_error(reason)
        error_msg = format_error(reason)
        Logger.error("Webhook delivery error for request #{request_updated.id}: #{error_msg}")

        handle_delivery_failure(request_updated, batch, outcome, error_msg)
    end
  end

  defp post_webhook(url, payload) do
    # Use configurable timeout - low for tests, reasonable for production
    http_timeouts = Application.get_env(:batcher, :http_timeouts, [])
    receive_timeout = Keyword.get(http_timeouts, :receive_timeout, 30_000)
    connect_timeout = Keyword.get(http_timeouts, :connect_timeout, 10_000)

    case Req.post(url,
           json: payload,
           headers: [{"content-type", "application/json"}],
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

  defp handle_delivery_result({:ok, request}, batch) do
    # Check if all requests in batch are delivered/failed
    check_batch_completion(batch)
    {:ok, request}
  end

  defp handle_delivery_failure(request, batch, outcome, error_msg) do
    # Mark request as delivery_failed (not :failed) because this is a delivery error,
    # not an OpenAI processing error. The error is recorded on the delivery_attempt.
    request_after =
      request
      |> Ash.Changeset.for_update(:mark_delivery_failed, %{})
      |> Ash.Changeset.put_context(:delivery_attempt, %{
        outcome: outcome,
        error_msg: error_msg
      })
      |> Ash.update!()

    # Check if all requests in batch are delivered/delivery_failed
    check_batch_completion(batch)
    {:ok, request_after}
  end

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

  defp check_batch_completion(batch) do
    # Efficiently check if all requests are in terminal states using calculation
    # This avoids loading all 50k requests into memory
    batch = Ash.load!(batch, [:requests_terminal_count, :delivery_stats])

    if batch.requests_terminal_count and batch.state == :delivering do
      %{delivered: delivered_count, failed: failed_count} = batch.delivery_stats

      {action, state_name} =
        cond do
          delivered_count > 0 and failed_count == 0 ->
            {:mark_delivered, "delivered"}

          delivered_count == 0 and failed_count > 0 ->
            {:mark_delivery_failed, "delivery_failed"}

          delivered_count > 0 and failed_count > 0 ->
            {:mark_partially_delivered, "partially_delivered"}

          true ->
            # Empty batch edge case
            {:mark_delivered, "delivered"}
        end

      batch
      |> Ash.Changeset.for_update(action)
      |> Ash.update!()

      Logger.info(
        "Batch #{batch.id} delivery complete - state: #{state_name} (#{delivered_count} delivered, #{failed_count} failed)"
      )
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
end
