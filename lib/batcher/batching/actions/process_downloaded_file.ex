defmodule Batcher.Batching.Actions.ProcessDownloadedFile do
  @moduledoc """
  Runs an Ash action callback for the batch/request workflow.
  """
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.{FileProcessing, Utils}

  @doc false
  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)

    batch = Batching.get_batch_by_id!(batch_id)

    output_file_id = batch.openai_output_file_id
    error_file_id = batch.openai_error_file_id

    Logger.info(
      "Starting download for batch #{batch.id} (output_file_id: #{inspect(output_file_id)}, error_file_id: #{inspect(error_file_id)})"
    )

    # Process output file if it exists
    output_result =
      case output_file_id do
        nil ->
          Logger.info("Batch #{batch.id} has no output file (all requests may have failed)")
          :ok

        file_id ->
          FileProcessing.process_file(batch.id, file_id, "output")
      end

    # Process error file if it exists
    error_result =
      case error_file_id do
        nil ->
          Logger.info("Batch #{batch.id} has no error file (all requests succeeded)")
          :ok

        file_id ->
          FileProcessing.process_file(batch.id, file_id, "error")
      end

    # Both files must process successfully
    case {output_result, error_result, output_file_id, error_file_id} do
      {:ok, :ok, nil, error_file_id} when not is_nil(error_file_id) ->
        # No output file but error file exists - all requests failed
        Logger.info(
          "Batch #{batch.id} has no output file but has error file - all requests failed, transitioning to failed"
        )

        case batch
             |> Ash.Changeset.for_update(:failed, %{error_msg: "All requests in batch failed"})
             |> Ash.update() do
          {:ok, failed_batch} = result ->
            persist_download_error(failed_batch, nil)
            result

          {:error, reason} = error ->
            persist_download_error(
              batch,
              "Failed to finalize fully failed batch: #{inspect(reason)}"
            )

            error
        end

      {:ok, :ok, _, _} ->
        case FileProcessing.finalize_and_determine_outcome(batch) do
          {:ok, final_batch} = result ->
            persist_download_error(final_batch, nil)
            result

          {:error, reason} = error ->
            persist_download_error(
              batch,
              "Failed to finalize processed download: #{inspect(reason)}"
            )

            error
        end

      {{:error, reason}, _, _, _} ->
        Logger.error("Batch #{batch.id} failed to process output file: #{inspect(reason)}")
        persist_download_error(batch, "Output file processing failed: #{inspect(reason)}")
        {:error, reason}

      {_, {:error, reason}, _, _} ->
        Logger.error("Batch #{batch.id} failed to process error file: #{inspect(reason)}")
        persist_download_error(batch, "Error file processing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp persist_download_error(batch, error_message) do
    _ =
      batch
      |> Ash.Changeset.for_update(:record_download_error, %{last_download_error: error_message})
      |> Ash.update()

    :ok
  end
end
