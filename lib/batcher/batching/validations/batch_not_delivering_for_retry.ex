defmodule Batcher.Batching.Validations.BatchNotDeliveringForRetry do
  @moduledoc """
  Prevents request redelivery while the parent batch is currently delivering.
  """
  use Ash.Resource.Validation

  alias Batcher.Batching

  @impl true
  @doc false
  def validate(changeset, _opts, _context) do
    case fetch_batch(changeset) do
      {:ok, %{state: :delivering}} ->
        {:error, message: "Batch cannot redeliver while it is currently delivering"}

      {:ok, _batch} ->
        :ok

      {:error, _error} ->
        {:error, message: "Unable to validate batch state for redelivery"}
    end
  end

  defp fetch_batch(%{data: %{batch_id: batch_id}}) when not is_nil(batch_id) do
    Batching.get_batch_by_id(batch_id)
  end

  defp fetch_batch(%{data: %{id: request_id}}) when not is_nil(request_id) do
    with {:ok, request} <- Batching.get_request_by_id(request_id, load: [:batch]),
         %{state: _} = batch <- request.batch do
      {:ok, batch}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :batch_not_loaded}
    end
  end

  defp fetch_batch(changeset) do
    batch_id =
      Ash.Changeset.get_attribute(changeset, :batch_id) ||
        Map.get(changeset.data, :batch_id)

    Batching.get_batch_by_id(batch_id)
  end
end
