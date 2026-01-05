defmodule Batcher.Batching.Validations.BatchCanAcceptRequest do
  use Ash.Resource.Validation
  alias Batcher.Batching

  @impl true
  def validate(changeset, _opts, _context) do
    batch_id = Ash.Changeset.get_attribute(changeset, :batch_id)

    # Use the non-bang version to handle missing batches gracefully
    case Batching.get_batch_by_id(batch_id, load: [:request_count, :batch_size_bytes]) do
      {:ok, batch} ->
        with :ok <- batch_is_building(batch),
             :ok <- batch_not_full(batch),
             :ok <- batch_not_too_large(batch) do
          :ok
        end

      {:error, _} ->
        {:error, field: :batch_id, message: "batch not found for given batch_id: #{inspect(batch_id)}"}
    end
  end

  defp batch_is_building(batch) do
    if batch.state == :building,
      do: :ok,
      else: {:error, field: :batch_id, message: "Batch is not in building state"}
  end

  defp batch_not_full(batch) do
    if batch.request_count < 50_000,
      do: :ok,
      else: {:error, field: :batch_id, message: "Batch is full (max 50_000 requests)"}
  end

  defp batch_not_too_large(batch) do
    limit = 100 * 1024 * 1024 # 100 MB (but 200MB is the hard limit)

    if (batch.batch_size_bytes || 0) < limit,
      do: :ok,
      else: {:error, field: :batch_id, message: "Batch size exceeds 100MB limit"}
  end
end
