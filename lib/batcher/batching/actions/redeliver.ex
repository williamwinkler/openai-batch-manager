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
    # Find all requests with delivery_failed state
    failed_requests =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id and state == :delivery_failed)
      |> Ash.read!()

    failed_count = length(failed_requests)
    Logger.info("Redelivering batch #{batch.id}: found #{failed_count} failed requests")

    if failed_count == 0 do
      # No failed requests to redeliver
      {:ok, batch}
    else
      # Transition batch to delivering state
      batch =
        batch
        |> Ash.Changeset.for_update(:begin_redeliver)
        |> Ash.update!()

      # Trigger retry_delivery on each failed request
      Enum.each(failed_requests, fn request ->
        request
        |> Ash.Changeset.for_update(:retry_delivery)
        |> Ash.update!()
      end)

      Logger.info("Batch #{batch.id} redelivery initiated for #{failed_count} requests")
      {:ok, batch}
    end
  end
end
