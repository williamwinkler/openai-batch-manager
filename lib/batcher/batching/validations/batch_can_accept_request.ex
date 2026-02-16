defmodule Batcher.Batching.Validations.BatchCanAcceptRequest do
  @moduledoc """
  Validation ensuring requests can be appended to an existing building batch.

  This module emits structured `Ash.Error.Changes.InvalidAttribute` exceptions with
  machine-readable reason atoms in `vars[:reason]` so callers can branch
  on failure type without relying on fragile message matching.
  """
  use Ash.Resource.Validation
  alias Ash.Error.Changes.InvalidAttribute
  alias Batcher.Batching
  @reason_batch_not_found :batch_not_found
  @reason_batch_not_building :batch_not_building
  @reason_batch_full :batch_full
  @reason_batch_size_would_exceed :batch_size_would_exceed

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
    incoming_request_size = incoming_request_size_bytes(changeset)

    # Use the non-bang version to handle missing batches gracefully
    case Batching.get_batch_by_id(batch_id, load: [:request_count, :size_bytes]) do
      {:ok, batch} ->
        with :ok <- batch_is_building(batch),
             :ok <- batch_not_full(batch),
             :ok <- batch_not_too_large(batch, incoming_request_size) do
          :ok
        end

      {:error, _} ->
        {:error,
         invalid_batch_error(
           @reason_batch_not_found,
           "batch not found for given batch_id: #{inspect(batch_id)}"
         )}
    end
  end

  defp batch_is_building(batch) do
    if batch.state == :building,
      do: :ok,
      else:
        {:error,
         invalid_batch_error(@reason_batch_not_building, "Batch is not in building state")}
  end

  defp batch_not_full(batch) do
    if batch.request_count < @max_requests_per_batch,
      do: :ok,
      else:
        {:error,
         invalid_batch_error(
           @reason_batch_full,
           "Batch is full (max #{@max_requests_per_batch} requests)"
         )}
  end

  defp batch_not_too_large(batch, incoming_request_size) do
    current_size = batch.size_bytes || 0
    prospective_size = current_size + incoming_request_size

    if prospective_size <= @max_batch_size_bytes do
      :ok
    else
      {:error,
       invalid_batch_error(
         @reason_batch_size_would_exceed,
         "Batch size would exceed #{format_bytes(@max_batch_size_bytes)} limit (current: #{format_bytes(current_size)}, incoming: #{format_bytes(incoming_request_size)}, prospective: #{format_bytes(prospective_size)})"
       )}
    end
  end

  defp invalid_batch_error(reason, message) do
    InvalidAttribute.exception(
      field: :batch_id,
      message: message,
      vars: %{reason: reason}
    )
  end

  defp incoming_request_size_bytes(changeset) do
    case Ash.Changeset.get_argument(changeset, :request_payload) do
      payload when is_map(payload) ->
        payload
        |> normalize_json_payload()
        |> JSON.encode!()
        |> byte_size()

      payload when is_binary(payload) ->
        byte_size(payload)

      _ ->
        0
    end
  end

  defp normalize_json_payload(payload) when is_struct(payload) do
    payload
    |> Map.from_struct()
    |> normalize_json_payload()
  end

  defp normalize_json_payload(payload) when is_map(payload) do
    payload
    |> Map.new(fn {key, value} -> {key, normalize_json_payload(value)} end)
  end

  defp normalize_json_payload(payload) when is_list(payload) do
    Enum.map(payload, &normalize_json_payload/1)
  end

  defp normalize_json_payload(payload), do: payload

  defp format_bytes(bytes) when bytes >= 1024 * 1024 do
    "#{div(bytes, 1024 * 1024)}MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{div(bytes, 1024)}KB"
  end

  defp format_bytes(bytes), do: "#{bytes}B"
end
