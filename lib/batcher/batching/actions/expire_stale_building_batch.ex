defmodule Batcher.Batching.Actions.ExpireStaleBuildingBatch do
  use Ash.Resource.Actions.Implementation
  require Logger

  alias Batcher.Batching

  @doc """
  Expires stale building batches that are older than 1 hour.
  - Empty batches are deleted (orphaned data)
  - Non-empty batches are transitioned to uploading state
  """
  @impl true
  def run(input, _opts, _context) do
    # Handle both direct calls (via :subject) and AshOban triggers (via params)
    batch =
      case Map.get(input, :subject) do
        nil ->
          # AshOban passes the primary key via params for generic actions
          batch_id = get_in(input.params, ["primary_key", "id"])
          Batching.get_batch_by_id!(batch_id)

        batch ->
          batch
      end

    current_batch = Batching.get_batch_by_id!(batch.id)

    if current_batch.request_count == 0 do
      # Delete empty batch - it's orphaned data
      Logger.info("Deleting empty batch #{batch.id} that has been building for over 1 hour")

      case Ash.destroy(batch) do
        :ok -> {:ok, nil}
        {:error, error} -> {:error, error}
      end
    else
      # Start upload for non-empty batch
      Batching.start_batch_upload(batch)
    end
  end
end
