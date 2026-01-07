defmodule Batcher.Batching.Changes.EnsureBatchHasRequests do
  use Ash.Resource.Change

  @doc """
  Ensures that a batch has at least one request before allowing upload.
  Prevents empty batches from being transitioned to uploading state.
  """
  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data
    batch_with_count = Ash.load!(batch, :request_count)

    if batch_with_count.request_count == 0 do
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
