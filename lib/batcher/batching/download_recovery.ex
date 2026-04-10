defmodule Batcher.Batching.DownloadRecovery do
  @moduledoc """
  Recovery helpers for batches that fail after OpenAI has already completed work.
  """
  require Logger
  require Ash.Query

  alias Batcher.Batching
  alias Batcher.Batching.FileProcessing
  alias Batcher.Repo

  @doc """
  Returns true when a failed or downloading batch has enough evidence of completed
  or recoverable work that we should recover it instead of hard-failing it.
  """
  def recoverable?(batch) do
    has_progress_markers?(batch) or recoverable_request_count(batch.id) > 0
  end

  @doc """
  Requeues recoverable requests for a failed batch before it transitions back into
  the delivery flow.
  """
  def prepare_failed_batch(batch) do
    batch
    |> load_requests()
    |> requeue_recoverable_requests()
  end

  @doc """
  Finalizes a failed batch that has been moved back to `ready_to_deliver`.
  """
  def finalize_failed_batch(batch) do
    latest_batch = Batching.get_batch_by_id!(batch.id)

    case FileProcessing.finalize_and_determine_outcome(latest_batch) do
      {:ok, final_batch} ->
        clear_download_error(final_batch)
        {:ok, final_batch}

      {:error, reason} = error ->
        persist_download_error(
          latest_batch,
          "Failed to finalize recovered batch: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Recovers a downloading batch in-place after the watchdog decides it should stop
  waiting for file-processing retries.
  """
  def recover_downloading_batch(batch) do
    latest_batch = Batching.get_batch_by_id!(batch.id)

    with {:ok, _result} <- prepare_failed_batch(latest_batch),
         {:ok, final_batch} <- FileProcessing.finalize_and_determine_outcome(latest_batch) do
      clear_download_error(final_batch)
      {:ok, final_batch}
    else
      {:error, reason} = error ->
        persist_download_error(
          latest_batch,
          "Failed to recover downloading batch: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Returns true when a failed request should be retried in a successor batch.
  """
  def retryable_failed_request?(%{state: :failed, error_msg: error_msg})
      when is_binary(error_msg) do
    case JSON.decode(error_msg) do
      {:ok, row_data} -> retryable_row?(row_data)
      _ -> false
    end
  end

  def retryable_failed_request?(_request), do: false

  defp load_requests(batch) do
    Ash.load!(batch, [:requests])
  end

  defp requeue_recoverable_requests(%{requests: requests} = batch) do
    requests_to_move =
      Enum.filter(requests, fn request ->
        request.state == :openai_processing or retryable_failed_request?(request)
      end)

    case requests_to_move do
      [] ->
        {:ok, %{moved_count: 0, target_batch_id: nil}}

      [first_request | _] ->
        target_batch = find_or_create_building_batch(first_request)

        Logger.warning(
          "Recovering batch #{batch.id}: moving #{length(requests_to_move)} requests to successor batch #{target_batch.id}"
        )

        result =
          Repo.transaction(fn ->
            Enum.reduce(requests_to_move, [], fn request, notifications ->
              request
              |> restart_request_with_notifications(target_batch.id)
              |> Enum.concat(notifications)
            end)
          end)

        case result do
          {:ok, notifications} ->
            Ash.Notifier.notify(notifications)
            {:ok, %{moved_count: length(requests_to_move), target_batch_id: target_batch.id}}

          {:error, reason} ->
            Logger.error("Failed batch recovery for batch #{batch.id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp restart_request_with_notifications(request, target_batch_id) do
    {_, notifications} =
      request
      |> Ash.Changeset.for_update(:restart_to_pending, %{
        batch_id: target_batch_id,
        response_payload: nil,
        error_msg: nil
      })
      |> Ash.update!(return_notifications?: true)

    notifications
  end

  defp recoverable_request_count(batch_id) do
    Batching.Request
    |> Ash.Query.filter(batch_id == ^batch_id)
    |> Ash.read!()
    |> Enum.count(fn request ->
      request.state == :openai_processing or retryable_failed_request?(request)
    end)
  end

  defp has_progress_markers?(batch) do
    not is_nil(batch.openai_output_file_id) or
      not is_nil(batch.openai_error_file_id) or
      (batch.openai_requests_completed || 0) > 0 or
      (batch.openai_requests_failed || 0) > 0
  end

  defp find_or_create_building_batch(request) do
    case Batching.find_building_batch(request.model, request.url) do
      {:ok, batch} -> batch
      {:error, _} -> Batching.create_batch!(request.model, request.url)
    end
  end

  defp retryable_row?(row_data) when is_map(row_data) do
    status_code = get_in(row_data, ["response", "status_code"])
    response_error = get_in(row_data, ["response", "body", "error"])
    error = response_error || row_data["error"]

    is_integer(status_code) and status_code >= 500 and
      (not is_nil(error) or is_nil(status_code) == false)
  end

  defp retryable_row?(_row_data), do: false

  defp clear_download_error(batch) do
    _ =
      batch
      |> Ash.Changeset.for_update(:record_download_error, %{last_download_error: nil})
      |> Ash.update()

    :ok
  end

  defp persist_download_error(batch, error_message) do
    _ =
      batch
      |> Ash.Changeset.for_update(:record_download_error, %{
        last_download_error: error_message
      })
      |> Ash.update()

    :ok
  end
end
