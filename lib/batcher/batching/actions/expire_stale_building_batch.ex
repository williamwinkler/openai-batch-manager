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
    batch =
      case Map.fetch(input, :instance) do
        {:ok, instance} -> instance
        :error -> Map.fetch!(input, :subject)
      end

    batch_with_count = Ash.load!(batch, :request_count)

    if batch_with_count.request_count == 0 do
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
