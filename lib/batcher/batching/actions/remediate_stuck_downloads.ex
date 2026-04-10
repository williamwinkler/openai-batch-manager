defmodule Batcher.Batching.Actions.RemediateStuckDownloads do
  @moduledoc """
  Remediates batches that remain in downloading for too long.
  """
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.DownloadRecovery
  alias Batcher.Batching.Utils

  @stale_after_seconds 15 * 60
  @hard_timeout_seconds 60 * 60

  @doc false
  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)
    batch = Batching.get_batch_by_id!(batch_id)

    case batch.state do
      :downloading ->
        remediate(batch)

      _ ->
        {:ok, batch}
    end
  end

  defp remediate(batch) do
    downloading_age_seconds = DateTime.diff(DateTime.utc_now(), batch.updated_at, :second)

    cond do
      downloading_age_seconds >= @hard_timeout_seconds ->
        timeout_minutes = div(@hard_timeout_seconds, 60)

        if DownloadRecovery.recoverable?(batch) do
          Logger.error(
            "Batch #{batch.id} watchdog timeout after #{timeout_minutes} minutes in downloading; recovering instead of failing"
          )

          DownloadRecovery.recover_downloading_batch(batch)
        else
          Logger.error(
            "Batch #{batch.id} watchdog timeout after #{timeout_minutes} minutes in downloading; transitioning to failed"
          )

          batch
          |> Ash.Changeset.for_update(:failed, %{
            error_msg:
              "Download watchdog timeout after #{timeout_minutes} minutes in downloading state"
          })
          |> Ash.update()
        end

      downloading_age_seconds >= @stale_after_seconds ->
        stale_minutes = div(@stale_after_seconds, 60)

        Logger.warning(
          "Batch #{batch.id} has been downloading for #{downloading_age_seconds}s (>= #{stale_minutes}m); re-enqueueing process_downloaded_file"
        )

        trigger = AshOban.Info.oban_trigger(Batching.Batch, :process_downloaded_file)

        try do
          AshOban.run_trigger(batch, trigger)
        rescue
          error ->
            Logger.warning(
              "Batch #{batch.id} watchdog failed to re-enqueue process_downloaded_file: #{inspect(error)}"
            )
        end

        {:ok, batch}

      true ->
        {:ok, batch}
    end
  end
end
