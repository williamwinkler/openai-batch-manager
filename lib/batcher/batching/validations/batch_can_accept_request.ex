defmodule Batcher.Batching.Validations.BatchCanAcceptRequest do
  use Ash.Resource.Validation
  alias Batcher.Batching

  @max_requests_per_batch Application.compile_env(
                             :batcher,
                             [:batch_limits, :max_requests_per_batch],
                             50_000
                           )

  @max_batch_size_bytes Application.compile_env(
                          :batcher,
                          [:batch_limits, :max_batch_size_bytes],
                          100 * 1024 * 1024
                        )

  @impl true
  def validate(changeset, _opts, _context) do
    batch_id = Ash.Changeset.get_attribute(changeset, :batch_id)

    # Use the non-bang version to handle missing batches gracefully
    case Batching.get_batch_by_id(batch_id, load: [:request_count, :size_bytes]) do
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
    if batch.request_count < @max_requests_per_batch,
      do: :ok,
      else:
        {:error,
         field: :batch_id,
         message: "Batch is full (max #{@max_requests_per_batch} requests)"}
  end

  defp batch_not_too_large(batch) do
    if (batch.size_bytes || 0) < @max_batch_size_bytes,
      do: :ok,
      else:
        {:error,
         field: :batch_id,
         message: "Batch size exceeds #{format_bytes(@max_batch_size_bytes)} limit"}
  end

  defp format_bytes(bytes) when bytes >= 1024 * 1024 do
    "#{div(bytes, 1024 * 1024)}MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{div(bytes, 1024)}KB"
  end

  defp format_bytes(bytes), do: "#{bytes}B"
end
