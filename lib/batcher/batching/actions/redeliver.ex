defmodule Batcher.Batching.Actions.Redeliver do
  @moduledoc """
  Redelivers requests in a batch as one-shot request retries.
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching

  @doc false
  def run(input, _opts, _context) do
    batch_id = input.arguments.id
    batch = Batching.get_batch_by_id!(batch_id)

    run_for_batch(batch, :all_deliverable)
  end

  @doc false
  def run_for_batch(batch, mode) do
    deliverable_query = deliverable_request_query(batch.id, mode)
    label = mode_label(mode)

    if batch.state == :delivering do
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           %Ash.Error.Changes.InvalidAttribute{
             field: :state,
             message: "Batch is already delivering"
           }
         ]
       )}
    else
      deliverable_requests = Ash.read!(deliverable_query)
      deliverable_count = length(deliverable_requests)
      queued_count = Enum.count(deliverable_requests, &(&1.state == :openai_processed))

      Logger.info(
        "Redelivering #{label} for batch #{batch.id}: found #{deliverable_count} requests (#{queued_count} already queued)"
      )

      if deliverable_count == 0 do
        Logger.info("Batch #{batch.id} has no #{label} requests to redeliver")
        {:ok, batch}
      else
        case Ash.bulk_update(deliverable_query, :retry_delivery, %{}, strategy: :stream) do
          %Ash.BulkResult{status: :success} ->
            Logger.info(
              "Batch #{batch.id} redelivery initiated for #{deliverable_count} #{label} requests"
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
      end
    end
  end

  defp deliverable_request_query(batch_id, :all_deliverable) do
    Batching.Request
    |> Ash.Query.filter(
      batch_id == ^batch_id and state != :delivering and not is_nil(response_payload)
    )
  end

  defp deliverable_request_query(batch_id, :failed_only) do
    Batching.Request
    |> Ash.Query.filter(
      batch_id == ^batch_id and state == :delivery_failed and not is_nil(response_payload)
    )
  end

  defp mode_label(:all_deliverable), do: "deliverable"
  defp mode_label(:failed_only), do: "failed deliverable"
end
