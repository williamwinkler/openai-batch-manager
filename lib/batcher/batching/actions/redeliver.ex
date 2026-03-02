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
    queued_count = queued_openai_processed_count(batch.id)

    Logger.info(
      "Redelivering batch #{batch.id}: found #{failed_count} failed requests and #{queued_count} queued requests"
    )

    if failed_count == 0 and queued_count == 0 do
      # Nothing to redeliver/resume
      {:ok, batch}
    else
      if rabbitmq_redelivery_blocked?(batch.id) do
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

        if failed_count > 0 do
          # Retry all currently failed requests in a single query-based update.
          # This avoids stale-record errors when request rows were updated concurrently.
          case Ash.bulk_update(failed_query, :retry_delivery, %{}, strategy: :stream) do
            %Ash.BulkResult{status: :success} ->
              Logger.info(
                "Batch #{batch.id} redelivery initiated for #{failed_count} failed requests (#{queued_count} queued requests resumed)"
              )

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
        else
          Logger.info("Batch #{batch.id} resumed delivery for #{queued_count} queued requests")
          {:ok, batch}
        end
      end
    end
  end

  defp rabbitmq_redelivery_blocked?(batch_id) do
    if Batcher.RabbitMQ.Publisher.connected?() do
      false
    else
      Batching.Request
      |> Ash.Query.filter(
        batch_id == ^batch_id and state in [:delivery_failed, :openai_processed]
      )
      |> Ash.Query.select([:delivery_config])
      |> Ash.read!()
      |> Enum.any?(fn request ->
        rabbitmq_delivery?(request.delivery_config)
      end)
    end
  end

  defp rabbitmq_delivery?(delivery_config) when is_map(delivery_config) do
    Map.get(delivery_config, "type") == "rabbitmq" or
      Map.get(delivery_config, :type) == "rabbitmq"
  end

  defp rabbitmq_delivery?(_), do: false

  defp queued_openai_processed_count(batch_id) do
    Batching.Request
    |> Ash.Query.filter(batch_id == ^batch_id and state == :openai_processed)
    |> Ash.count!()
  end
end
