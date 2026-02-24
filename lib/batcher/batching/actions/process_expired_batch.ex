defmodule Batcher.Batching.Actions.ProcessExpiredBatch do
  @moduledoc """
  Processes partial results from an expired OpenAI batch.

  When OpenAI expires a batch (24h timeout), some requests may have been processed.
  This action downloads available output/error files, updates processed requests,
  resets remaining unprocessed requests to :pending, and either finalizes the batch
  (if all requests are done) or re-uploads only the unprocessed requests.
  """

  require Logger
  require Ash.Query

  alias Batcher.Batching
  alias Batcher.Batching.{FileProcessing, Utils}

  @doc false
  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)
    batch = Batching.get_batch_by_id!(batch_id)

    output_file_id = batch.openai_output_file_id
    error_file_id = batch.openai_error_file_id

    Logger.info(
      "Processing expired batch #{batch.id} with partial results " <>
        "(output_file_id: #{inspect(output_file_id)}, error_file_id: #{inspect(error_file_id)})"
    )

    # Download and process available files
    output_result =
      case output_file_id do
        nil -> :ok
        file_id -> FileProcessing.process_file(batch.id, file_id, "output")
      end

    error_result =
      case error_file_id do
        nil -> :ok
        file_id -> FileProcessing.process_file(batch.id, file_id, "error")
      end

    # If both downloads fail, fall back to full resubmission
    both_failed? =
      match?({:error, _}, output_result) and match?({:error, _}, error_result)

    if both_failed? do
      Logger.warning(
        "Batch #{batch.id}: both output and error file downloads failed, " <>
          "falling back to full resubmission"
      )
    end

    # Reset remaining :openai_processing requests to :pending
    reset_count = reset_processing_requests_to_pending(batch.id)

    Logger.info("Batch #{batch.id}: reset #{reset_count} openai_processing requests to pending")

    # Count remaining pending requests
    pending_count =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.filter(state == :pending)
      |> Ash.count!()

    Logger.info("Batch #{batch.id}: #{pending_count} pending requests remaining")

    if pending_count == 0 do
      # All requests have been processed (either from files or already terminal)
      Logger.info("Batch #{batch.id}: all requests processed, finalizing")
      FileProcessing.finalize_and_determine_outcome(batch)
    else
      # Re-upload only the unprocessed requests
      Logger.info("Batch #{batch.id}: re-uploading #{pending_count} unprocessed requests")

      batch
      |> Ash.Changeset.for_update(:reupload_unprocessed)
      |> Ash.update()
    end
  end

  defp reset_processing_requests_to_pending(batch_id) do
    requests =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch_id)
      |> Ash.Query.filter(state == :openai_processing)
      |> Ash.read!()

    Enum.each(requests, fn request ->
      request
      |> Ash.Changeset.for_update(:bulk_reset_to_pending)
      |> Ash.update!()
    end)

    length(requests)
  end
end
