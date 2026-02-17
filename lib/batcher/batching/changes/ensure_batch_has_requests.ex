defmodule Batcher.Batching.Changes.EnsureBatchHasRequests do
  use Ash.Resource.Change

  @doc """
  Ensures that a batch has at least one request before allowing upload.
  Prevents empty batches from being transitioned to uploading state.
  """
  @impl true
  def change(changeset, _opts, _context) do
    batch = Batcher.Batching.get_batch_by_id!(changeset.data.id)

    if batch.request_count == 0 do
      Ash.Changeset.add_error(
        changeset,
        field: :id,
        message: "Cannot upload empty batch - batch has no requests"
      )
    else
      changeset
    end
  end
end
