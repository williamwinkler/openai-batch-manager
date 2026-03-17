defmodule Batcher.Batching.Changes.EnqueuePendingDeliveries do
  @moduledoc """
  Enqueues delivery jobs for all `:openai_processed` requests in the batch.

  This is used when a batch transitions to `:delivering` so request delivery
  starts only after download/processing is fully finalized.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Batcher.Batching
  @default_chunk_size 200
  @default_max_error_logs 5
  @stats_zero %{attempted: 0, enqueued: 0, failed: 0, logged_failures: 0}

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, batch} ->
          enqueue_pending_deliveries(batch)
          {:ok, batch}

        {:error, _} = error ->
          error
      end
    end)
  end

  def enqueue_pending_deliveries(batch) do
    trigger = AshOban.Info.oban_trigger(Batching.Request, :deliver)
    chunk_size = @default_chunk_size
    max_error_logs = @default_max_error_logs

    started_at = System.monotonic_time()

    stats =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id and state == :openai_processed)
      |> Ash.Query.select([:id])
      |> Ash.stream!()
      |> Stream.chunk_every(chunk_size)
      |> Enum.reduce(@stats_zero, fn chunk, acc ->
        Enum.reduce(chunk, acc, fn request, stats ->
          enqueue_request(batch, request, trigger, max_error_logs, stats)
        end)
      end)

    log_summary(batch.id, started_at, stats)
  end

  defp enqueue_request(batch, request, trigger, max_error_logs, stats) do
    try do
      AshOban.run_trigger(request, trigger)
      %{stats | attempted: stats.attempted + 1, enqueued: stats.enqueued + 1}
    rescue
      error ->
        logged_failures =
          maybe_log_failure(batch.id, request.id, error, stats.logged_failures, max_error_logs)

        %{
          stats
          | attempted: stats.attempted + 1,
            failed: stats.failed + 1,
            logged_failures: logged_failures
        }
    end
  end

  defp maybe_log_failure(batch_id, request_id, error, logged_failures, max_error_logs)
       when logged_failures < max_error_logs do
    Logger.warning(
      "Failed to enqueue delivery trigger for request #{request_id} in batch #{batch_id}: #{inspect(error)}"
    )

    logged_failures + 1
  end

  defp maybe_log_failure(_batch_id, _request_id, _error, logged_failures, _max_error_logs),
    do: logged_failures

  defp log_summary(batch_id, started_at, stats) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    suppressed_failures = stats.failed - stats.logged_failures

    message =
      "Delivery enqueue summary for batch #{batch_id}: attempted=#{stats.attempted}, " <>
        "enqueued=#{stats.enqueued}, failed=#{stats.failed}, " <>
        "suppressed_failures=#{suppressed_failures}, duration_ms=#{duration_ms}"

    if stats.failed == 0 do
      Logger.info(message)
    else
      Logger.warning(message)
    end
  end
end
