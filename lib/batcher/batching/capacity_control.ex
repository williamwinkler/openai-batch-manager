defmodule Batcher.Batching.CapacityControl do
  @moduledoc """
  Capacity admission checks for OpenAI batch creation.
  """
  require Ash.Query
  require Logger

  alias Batcher.Batching

  @active_reservation_states [
    :openai_processing,
    :openai_completed,
    :downloading,
    :ready_to_deliver,
    :delivering
  ]

  @doc """
  Computes the admission decision for a batch.
  """
  @spec decision(Batching.Batch.t()) ::
          {:admit, map()} | {:wait_capacity_blocked, map()}
  def decision(batch) do
    with {:ok, %{limit: limit, source: source}} <-
           Batcher.OpenaiRateLimits.get_batch_limit_tokens(batch.model),
         {:ok, reserved} <- reserved_tokens_for_model(batch.model, exclude_batch_id: batch.id) do
      headroom = max(limit - reserved, 0)
      needed = batch.estimated_input_tokens_total || 0

      context = %{
        model: batch.model,
        limit: limit,
        limit_source: source,
        reserved: reserved,
        headroom: headroom,
        needed: needed
      }

      if fits_headroom?(batch, reserved, limit) do
        {:admit, context}
      else
        {:wait_capacity_blocked, context}
      end
    else
      _ ->
        {:wait_capacity_blocked, %{reason: :capacity_check_failed, model: batch.model}}
    end
  end

  @doc """
  Returns true when the given batch can fit the model's remaining queue headroom.
  """
  @spec fits_headroom?(Batching.Batch.t(), non_neg_integer(), pos_integer()) :: boolean()
  def fits_headroom?(batch, reserved, limit) do
    needed = batch.estimated_input_tokens_total || 0
    headroom = max(limit - reserved, 0)
    needed <= headroom
  end

  @doc """
  Returns reserved tokens for active batches of a model.

  Active reservation states represent batches that are already consuming OpenAI
  queue headroom and should be subtracted from available capacity.
  """
  @spec reserved_tokens_for_model(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def reserved_tokens_for_model(model, opts \\ []) when is_binary(model) do
    exclude_batch_id = Keyword.get(opts, :exclude_batch_id)

    query =
      Batching.Batch
      |> Ash.Query.filter(model == ^model and state in ^@active_reservation_states)
      |> maybe_exclude_batch(exclude_batch_id)
      |> Ash.Query.select([:estimated_input_tokens_total])

    total =
      query
      |> Ash.read!()
      |> Enum.reduce(0, fn batch, acc -> acc + (batch.estimated_input_tokens_total || 0) end)

    {:ok, total}
  rescue
    error ->
      Logger.error("Failed to compute reserved tokens for model #{model}: #{inspect(error)}")
      {:ok, 0}
  end

  @doc """
  Returns true when a building batch should be rotated/uploaded immediately because
  its own estimated tokens hit the model queue limit.

  This check intentionally ignores currently reserved tokens from other active
  batches so ingestion can keep appending requests to the same building batch
  while OpenAI queue headroom is temporarily exhausted.
  """
  @spec should_rotate_building_batch?(Batching.Batch.t()) :: boolean()
  def should_rotate_building_batch?(batch) do
    with {:ok, %{limit: limit}} <- Batcher.OpenaiRateLimits.get_batch_limit_tokens(batch.model) do
      (batch.estimated_input_tokens_total || 0) >= limit
    else
      _ -> false
    end
  end

  defp maybe_exclude_batch(query, nil), do: query
  defp maybe_exclude_batch(query, batch_id), do: Ash.Query.filter(query, id != ^batch_id)
end
