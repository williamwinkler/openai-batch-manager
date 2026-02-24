defmodule Batcher.Batching.Changes.EnqueueDeliveryTrigger do
  @moduledoc """
  Enqueues the request delivery trigger immediately after processing completes.

  Failures are logged and swallowed so request processing is not blocked. The
  trigger scheduler remains as a fallback safety net.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      trigger = AshOban.Info.oban_trigger(Batcher.Batching.Request, :deliver)

      try do
        AshOban.run_trigger(result, trigger)
      rescue
        error ->
          Logger.warning(
            "Failed to enqueue immediate delivery trigger for request #{result.id}: #{inspect(error)}"
          )
      end

      {:ok, result}
    end)
  end
end
