defmodule Batcher.Batching.ObanJobs do
  @moduledoc """
  Helpers for managing Oban jobs related to batch processing.
  """

  import Ecto.Query

  require Logger

  alias Batcher.Repo
  alias Oban.Job

  @cancellable_states ["available", "scheduled", "retryable", "executing"]

  @batch_workers [
    Batcher.Batching.Batch.AshOban.Worker.UploadBatch,
    Batcher.Batching.Batch.AshOban.Worker.CreateOpenaiBatch,
    Batcher.Batching.Batch.AshOban.Worker.CheckBatchStatus,
    Batcher.Batching.Batch.AshOban.Worker.StartDownloading,
    Batcher.Batching.Batch.AshOban.Worker.ProcessDownloadedFile,
    Batcher.Batching.Batch.AshOban.Worker.ProcessExpiredBatch,
    Batcher.Batching.Batch.AshOban.Worker.CheckDeliveryCompletion,
    Batcher.Batching.Batch.AshOban.Worker.ExpireStaleBuildingBatch
  ]

  @batch_worker_names Enum.map(@batch_workers, fn worker ->
                        worker
                        |> Atom.to_string()
                        |> String.trim_leading("Elixir.")
                      end)

  @spec cancel_batch_jobs(integer()) :: :ok | {:error, list()}
  def cancel_batch_jobs(batch_id) when is_integer(batch_id) do
    jobs =
      Job
      |> where([job], job.worker in ^@batch_worker_names)
      |> where([job], job.state in ^@cancellable_states)
      |> Repo.all()
      |> Enum.filter(&job_for_batch?(&1, batch_id))

    {cancelled_count, errors} =
      Enum.reduce(jobs, {0, []}, fn job, {count, acc_errors} ->
        case Oban.cancel_job(job.id) do
          :ok ->
            {count + 1, acc_errors}

          {:error, reason} ->
            {count, [{job.id, reason} | acc_errors]}
        end
      end)

    if errors == [] do
      Logger.info("Cancelled #{cancelled_count} Oban batch jobs for batch #{batch_id}")
      :ok
    else
      Logger.error(
        "Failed cancelling #{length(errors)} Oban batch jobs for batch #{batch_id}: #{inspect(errors)}"
      )

      {:error, Enum.reverse(errors)}
    end
  end

  defp job_for_batch?(%Job{args: args}, batch_id) do
    args
    |> extract_batch_id()
    |> normalize_id()
    |> Kernel.==(normalize_id(batch_id))
  end

  defp extract_batch_id(args) do
    get_in(args, ["params", "primary_key", "id"]) ||
      get_in(args, ["primary_key", "id"]) ||
      get_in(args, [:params, :primary_key, :id]) ||
      get_in(args, [:primary_key, :id])
  end

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(_), do: nil
end
