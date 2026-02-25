defmodule Batcher.Batching.Handlers.RequestHandler do
  @moduledoc """
  Coordinates request intake and assignment into batches.
  """
  alias Batcher.Batching.BatchBuilder
  require Logger

  def handle(request_data) when is_map(request_data) do
    %{url: url, body: %{model: model}} = request_data
    assign_to_batch(url, model, request_data)
  end

  defp assign_to_batch(url, model, request_data) do
    %{custom_id: custom_id} = request_data

    case BatchBuilder.add_request(url, model, request_data) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} when reason in [:batch_full, :batch_not_building] ->
        Logger.info(
          "Batch for url=#{url} model=#{model} is rotating (#{reason}). Will try to add request #{custom_id} to a new batch"
        )

        # Try again
        BatchBuilder.add_request(url, model, request_data)

      {:error, :custom_id_already_taken} ->
        Logger.info("Duplicate custom_id rejected: #{request_data.custom_id}")
        {:error, :custom_id_already_taken}

      {:error, %Ash.Error.Invalid{} = error} ->
        Logger.info("Request validation failed during batch assignment",
          custom_id: request_data.custom_id,
          error: inspect(error, pretty: true)
        )

        {:error, error}

      error ->
        Logger.error("Failed to add request to batch: #{inspect(error)}")
        {:error, {:batch_assignment_error, inspect(error)}}
    end
  end
end
