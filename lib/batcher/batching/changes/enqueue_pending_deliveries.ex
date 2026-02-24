defmodule Batcher.Batching.Changes.EnqueuePendingDeliveries do
  @moduledoc """
  Enqueues delivery jobs for all `:openai_processed` requests in the batch.

  This is used when a batch transitions to `:delivering` so request delivery
  starts only after download/processing is fully finalized.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Batcher.Batching

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn _changeset, batch ->
      trigger = AshOban.Info.oban_trigger(Batching.Request, :deliver)

      requests =
        Batching.Request
        |> Ash.Query.filter(batch_id == ^batch.id and state == :openai_processed)
        |> Ash.read!()

      Enum.each(requests, fn request ->
        try do
          AshOban.run_trigger(request, trigger)
        rescue
          error ->
            Logger.warning(
              "Failed to enqueue delivery trigger for request #{request.id} in batch #{batch.id}: #{inspect(error)}"
            )
        end
      end)

      {:ok, batch}
    end)
  end
end
