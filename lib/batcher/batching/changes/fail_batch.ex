defmodule Batcher.Batching.Changes.FailBatch do
  @moduledoc """
  Runs an Ash change callback for batch lifecycle updates.
  """
  use Ash.Resource.Change
  require Logger

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      batch = changeset.data

      if batch.state == :openai_processing and batch.openai_batch_id do
        Logger.info("Marking all requests as failed for batch #{batch.id}")

        Batcher.Batching.Request
        |> Ash.Query.filter(batch_id == ^batch.id)
        |> Ash.bulk_update!(:mark_failed, %{error_msg: "Batch failed"}, strategy: :stream)
      end

      changeset
    end)
  end
end
