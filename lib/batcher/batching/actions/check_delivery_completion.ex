defmodule Batcher.Batching.Actions.CheckDeliveryCompletion do
  @moduledoc """
  Checks if all requests in a delivering batch are in terminal states,
  and if so, transitions the batch to the appropriate delivery state:
  - :delivered - all requests delivered successfully
  - :partially_delivered - some requests delivered, some failed
  - :delivery_failed - all requests failed to deliver

  This is a safety net to catch batches that may have been left in the
  delivering state due to race conditions when multiple deliveries complete
  simultaneously.
  """
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.Utils

  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)

    batch =
      Batching.get_batch_by_id!(batch_id)
      |> Ash.load!([:requests_terminal_count, :delivery_stats])

    cond do
      batch.state != :delivering ->
        # Batch is no longer in delivering state, nothing to do
        Logger.debug("Batch #{batch.id} is not in delivering state (#{batch.state}), skipping")
        {:ok, batch}

      batch.requests_terminal_count ->
        # All requests are in terminal states, determine appropriate final state
        transition_to_delivery_state(batch)

      true ->
        # Still has requests being delivered
        Logger.debug("Batch #{batch.id} still has requests being delivered")
        {:ok, batch}
    end
  end

  defp transition_to_delivery_state(batch) do
    %{delivered: delivered_count, failed: failed_count} = batch.delivery_stats

    # Re-fetch the batch to get the current state and avoid race conditions
    # with concurrent check_delivery_completion jobs
    fresh_batch = Batching.get_batch_by_id!(batch.id)

    if fresh_batch.state != :delivering do
      Logger.debug(
        "Batch #{batch.id} is no longer in delivering state (#{fresh_batch.state}), skipping transition"
      )

      {:ok, fresh_batch}
    else
      cond do
        delivered_count > 0 and failed_count == 0 ->
          # All requests delivered successfully
          Logger.info("Batch #{batch.id} has all requests delivered successfully")

          fresh_batch
          |> Ash.Changeset.for_update(:mark_delivered)
          |> Ash.update()

        delivered_count == 0 and failed_count > 0 ->
          # All requests failed to deliver
          Logger.info("Batch #{batch.id} has all requests failed to deliver")

          fresh_batch
          |> Ash.Changeset.for_update(:mark_delivery_failed)
          |> Ash.update()

        delivered_count > 0 and failed_count > 0 ->
          # Mixed results - some delivered, some failed
          Logger.info(
            "Batch #{batch.id} has mixed delivery results (#{delivered_count} delivered, #{failed_count} failed)"
          )

          fresh_batch
          |> Ash.Changeset.for_update(:mark_partially_delivered)
          |> Ash.update()

        true ->
          # Edge case: empty batch (no requests) - mark as delivered
          Logger.info("Batch #{batch.id} has no requests, marking as delivered")

          fresh_batch
          |> Ash.Changeset.for_update(:mark_delivered)
          |> Ash.update()
      end
    end
  end
end
