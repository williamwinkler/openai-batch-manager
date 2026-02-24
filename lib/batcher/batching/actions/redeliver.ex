defmodule Batcher.Batching.Actions.Redeliver do
  @moduledoc """
  Redelivers all failed requests in a batch.

  This action:
  1. Transitions the batch from :partially_delivered or :delivery_failed to :delivering
  2. Finds all requests with :delivery_failed state
  3. Triggers retry_delivery on each of them, which schedules new delivery jobs
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching

  @doc false
  def run(input, _opts, _context) do
    batch_id = input.arguments.id

    batch = Batching.get_batch_by_id!(batch_id)

    if batch.state not in [:partially_delivered, :delivery_failed] do
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           %Ash.Error.Changes.InvalidAttribute{
             field: :state,
             message: "Batch must be in partially_delivered or delivery_failed state to redeliver"
           }
         ]
       )}
    else
      redeliver_batch(batch)
    end
  end

  defp redeliver_batch(batch) do
    failed_query =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id and state == :delivery_failed)

    failed_requests = Ash.read!(failed_query)
    failed_count = length(failed_requests)

    Logger.info("Redelivering batch #{batch.id}: found #{failed_count} failed requests")

    if failed_count == 0 do
      # No failed requests to redeliver
      {:ok, batch}
    else
      if rabbitmq_redelivery_blocked?(failed_requests) do
        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidAttribute{
               field: :delivery_config,
               message:
                 "RabbitMQ is disconnected. Reconnect RabbitMQ before redelivering RabbitMQ requests."
             }
           ]
         )}
      else
        # Transition batch to delivering state
        batch =
          batch
          |> Ash.Changeset.for_update(:begin_redeliver)
          |> Ash.update!()

        # Retry all currently failed requests in a single query-based update.
        # This avoids stale-record errors when request rows were updated concurrently.
        case Ash.bulk_update(failed_query, :retry_delivery, %{}, strategy: :stream) do
          %Ash.BulkResult{status: :success} ->
            Logger.info("Batch #{batch.id} redelivery initiated for #{failed_count} requests")
            {:ok, batch}

          %Ash.BulkResult{status: :error, errors: errors} ->
            {:error,
             Ash.Error.Invalid.exception(
               errors:
                 Enum.map(errors, fn error ->
                   if is_exception(error) do
                     error
                   else
                     %Ash.Error.Changes.InvalidAttribute{
                       field: :state,
                       message: inspect(error)
                     }
                   end
                 end)
             )}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defp rabbitmq_redelivery_blocked?(requests) do
    Enum.any?(requests, fn request ->
      rabbitmq_delivery?(request.delivery_config)
    end) and not Batcher.RabbitMQ.Publisher.connected?()
  end

  defp rabbitmq_delivery?(delivery_config) when is_map(delivery_config) do
    Map.get(delivery_config, "type") == "rabbitmq" or
      Map.get(delivery_config, :type) == "rabbitmq"
  end

  defp rabbitmq_delivery?(_), do: false
end
