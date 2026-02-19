defmodule Batcher.Batching.Actions.DispatchWaitingForCapacity do
  @moduledoc """
  Dispatches waiting batches in oldest-fit-first order per model.
  """
  require Ash.Query
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.CapacityControl
  alias Batcher.Batching.Utils

  @doc """
  Re-evaluates waiting batches for the same model as the provided batch and
  starts eligible ones that fit current headroom in oldest-first order.

  The function is intentionally best-effort and returns `{:ok, batch}` even when
  no waiting batch could be admitted in the current run.
  """
  @spec run(struct(), keyword(), map()) :: {:ok, struct()} | {:error, term()}
  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)
    batch = Batching.get_batch_by_id!(batch_id)

    if batch.state in [:uploaded, :waiting_for_capacity, :expired] do
      dispatch_model_waiting_queue(batch.model)
      maybe_enqueue_or_start_batch(batch.id)
    end

    {:ok, Batching.get_batch_by_id!(batch.id)}
  end

  defp dispatch_model_waiting_queue(model) do
    model
    |> fetch_waiting_batches()
    |> dispatch_fittable_waiting_batches()
  rescue
    error ->
      Logger.error("Failed waiting-capacity dispatch for model #{model}: #{inspect(error)}")
      :ok
  end

  defp maybe_enqueue_or_start_batch(batch_id) do
    case Batching.get_batch_by_id(batch_id) do
      {:ok, batch} when batch.state in [:uploaded, :expired] ->
        case CapacityControl.decision(batch) do
          {:admit, _ctx} ->
            _ = batch |> Ash.Changeset.for_update(:create_openai_batch, %{}) |> Ash.update()
            :ok

          {:wait_capacity_blocked, _ctx} ->
            _ =
              Batching.wait_for_capacity(batch, %{capacity_wait_reason: "insufficient_headroom"})

            :ok
        end

      _ ->
        :ok
    end
  end

  defp fetch_waiting_batches(model) do
    Batching.Batch
    |> Ash.Query.filter(
      model == ^model and state == :waiting_for_capacity and
        (is_nil(token_limit_retry_next_at) or token_limit_retry_next_at <= now())
    )
    |> Ash.Query.sort(waiting_for_capacity_since_at: :asc, id: :asc)
    |> Ash.read!()
  end

  defp dispatch_fittable_waiting_batches(waiting_batches) do
    case pick_first_fittable(waiting_batches) do
      {:ok, nil} ->
        :ok

      {:ok, batch} ->
        case batch
             |> Ash.Changeset.for_update(:create_openai_batch, %{})
             |> Ash.update() do
          {:ok, _updated_batch} ->
            remaining = Enum.reject(waiting_batches, &(&1.id == batch.id))
            dispatch_fittable_waiting_batches(remaining)

          {:error, error} ->
            Logger.error(
              "Failed to dispatch waiting batch #{batch.id} for model #{batch.model}: #{inspect(error)}"
            )

            :ok
        end
    end
  end

  defp pick_first_fittable(waiting_batches) do
    Enum.reduce_while(waiting_batches, {:ok, nil}, fn batch, _acc ->
      latest_batch = Batching.get_batch_by_id!(batch.id)

      case CapacityControl.decision(latest_batch) do
        {:admit, _ctx} ->
          {:halt, {:ok, latest_batch}}

        {:wait_capacity_blocked, _ctx} ->
          _ =
            Batching.touch_waiting_for_capacity(latest_batch, %{
              capacity_wait_reason: "insufficient_headroom"
            })

          {:cont, {:ok, nil}}
      end
    end)
  end
end
