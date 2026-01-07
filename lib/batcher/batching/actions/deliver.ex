defmodule Batcher.Batching.Actions.Deliver do
  @moduledoc """
  Delivers the response_payload to the configured webhook_url or RabbitMQ queue.

  For webhook delivery:
  - POSTs response_payload to webhook_url
  - Records delivery attempt (success or failure)
  - On success: transitions request to :delivered
  - On failure: marks as :failed (no retries)
  - Saves webhook response body in error_msg for debugging

  For RabbitMQ delivery:
  - Currently raises error (not yet supported)
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching

  def run(input, _opts, _context) do
    request_id =
      case Map.fetch(input, :subject) do
        {:ok, %{id: id}} -> id
        _ -> get_in(input.params, ["primary_key", "id"])
      end

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
    case request.delivery_type do
      :rabbitmq ->
        error_msg = "RabbitMQ delivery not yet supported"
        Logger.error("RabbitMQ delivery attempted for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :delivery_type,
               message: error_msg
             }
           ]
         )}

      :webhook ->
        deliver_webhook(request)
    end
  end

  defp deliver_webhook(request) do
    # Validate required fields
    cond do
      is_nil(request.webhook_url) ->
        error_msg = "webhook_url is required for webhook delivery"
        Logger.error("Delivery failed for request #{request.id}: #{error_msg}")

        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :webhook_url,
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
        perform_webhook_delivery(request)
    end
  end

  defp perform_webhook_delivery(request) do
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
    case post_webhook(request_updated.webhook_url, request_updated.response_payload) do
      {:ok, status, _headers, _body} when status >= 200 and status < 300 ->
        # Success
        Logger.info(
          "Webhook delivery successful for request #{request_updated.id} (status: #{status})"
        )

        request_after =
          request_updated
          |> Ash.Changeset.for_update(:complete_delivery)
          |> Ash.Changeset.put_context(:delivery_attempt, %{
            success: true,
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

        handle_delivery_failure(request_updated, batch, error_msg)

      {:error, reason} ->
        # Network error
        error_msg = format_error(reason)
        Logger.error("Webhook delivery error for request #{request_updated.id}: #{error_msg}")

        handle_delivery_failure(request_updated, batch, error_msg)
    end
  end

  defp post_webhook(url, payload) do
    case Req.post(url,
           json: payload,
           headers: [{"content-type", "application/json"}],
           retry: false,
           receive_timeout: 30_000
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

  defp handle_delivery_failure(request, batch, error_msg) do
    # Mark request as failed
    request_after =
      request
      |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
      |> Ash.Changeset.put_context(:delivery_attempt, %{
        success: false,
        error_msg: error_msg
      })
      |> Ash.update!()

    # Check if all requests in batch are delivered/failed
    check_batch_completion(batch)
    {:ok, request_after}
  end

  defp check_batch_completion(batch) do
    # Efficiently check if all requests are in terminal states using calculation
    # This avoids loading all 50k requests into memory
    batch = Ash.load!(batch, :requests_terminal_count)

    if batch.requests_terminal_count and batch.state == :delivering do
      batch
      |> Ash.Changeset.for_update(:done)
      |> Ash.update!()

      Logger.info("Batch #{batch.id} delivery complete - all requests delivered or failed")
    end
  end

  defp encode_response_body(body) when is_binary(body) do
    # Try to parse as JSON, if it fails, return as-is
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded)
      {:error, _} -> body
    end
  end

  defp encode_response_body(body) when is_map(body) do
    Jason.encode!(body)
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
