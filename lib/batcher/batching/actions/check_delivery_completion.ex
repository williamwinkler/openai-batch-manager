defmodule Batcher.Batching.Actions.CheckDeliveryCompletion do
  @moduledoc """
  Checks if all requests in a delivering batch are in terminal states,
  and if so, transitions the batch to done.

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
      |> Ash.load!(:requests_terminal_count)

    cond do
      batch.state != :delivering ->
        # Batch is no longer in delivering state, nothing to do
        Logger.debug("Batch #{batch.id} is not in delivering state (#{batch.state}), skipping")
        {:ok, batch}

      batch.requests_terminal_count ->
        # All requests are in terminal states, transition to done
        Logger.info("Batch #{batch.id} has all requests in terminal states, marking as done")

        batch
        |> Ash.Changeset.for_update(:done)
        |> Ash.update()

      true ->
        # Still has requests being delivered
        Logger.debug("Batch #{batch.id} still has requests being delivered")
        {:ok, batch}
    end
  end
end
