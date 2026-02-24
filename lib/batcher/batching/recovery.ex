defmodule Batcher.Batching.Recovery do
  @moduledoc """
  Recovery helpers for re-enqueuing stuck batch workflow triggers after restarts.
  """

  require Ash.Query
  require Logger

  alias Batcher.Batching

  def resume_stale_work do
    enqueue_batches(:openai_completed, :start_downloading)
    enqueue_batches(:downloading, :process_downloaded_file)
    :ok
  end

  defp enqueue_batches(state, trigger_name) do
    trigger = AshOban.Info.oban_trigger(Batching.Batch, trigger_name)

    batches =
      Batching.Batch
      |> Ash.Query.filter(state == ^state)
      |> Ash.read!()

    Enum.each(batches, fn batch ->
      try do
        AshOban.run_trigger(batch, trigger)
      rescue
        error ->
          Logger.warning(
            "Failed to re-enqueue #{trigger_name} for batch #{batch.id} in state #{state}: #{inspect(error)}"
          )
      end
    end)
  end
end
