defmodule Batcher.Batching.Changes.CleanupOnDestroy do
  @moduledoc """
  Cleans up external resources when a batch is destroyed.

  This change:
  1. Cancels OpenAI batch if in :openai_processing state
  2. Deletes OpenAI files (fire-and-forget)

  Note: BatchBuilder termination is handled via pub_sub events (batches:destroyed:*)
  """
  use Ash.Resource.Change
  require Logger

  alias Batcher.OpenaiApiClient

  @impl true
  def change(changeset, _opts, _ctx) do
    # Run cleanup before the destroy action
    Ash.Changeset.before_action(changeset, fn cs ->
      batch = cs.data

      Logger.info("Destroying batch #{batch.id} (state: #{batch.state})")

      # 1. Cancel OpenAI batch if in processing state
      cancel_openai_batch_if_needed(batch)

      # 2. Delete OpenAI files (fire-and-forget)
      delete_openai_files(batch)

      # Note: BatchBuilder termination is handled via pub_sub events

      # Return changeset unchanged - the actual destroy will happen after this
      cs
    end)
  end

  defp cancel_openai_batch_if_needed(batch) do
    # If batch is in :openai_processing state and has openai_batch_id, cancel it
    # Proceed regardless of response (200 or 404 both proceed)
    if batch.state == :openai_processing and batch.openai_batch_id do
      Logger.info("Cancelling OpenAI batch #{batch.openai_batch_id} for batch #{batch.id}")

      case OpenaiApiClient.cancel_batch(batch.openai_batch_id) do
        {:ok, _} ->
          Logger.info("Successfully cancelled OpenAI batch #{batch.openai_batch_id}")

        {:error, :not_found} ->
          Logger.info(
            "OpenAI batch #{batch.openai_batch_id} not found (may already be cancelled)"
          )

        {:error, error} ->
          Logger.warning(
            "Failed to cancel OpenAI batch #{batch.openai_batch_id}: #{inspect(error)}"
          )
      end
    end
  end

  defp delete_openai_files(batch) do
    # Delete input, output, and error files if present
    # Fire requests but don't wait for or care about responses (fire-and-forget)
    files_to_delete = [
      {batch.openai_input_file_id, "input"},
      {batch.openai_output_file_id, "output"},
      {batch.openai_error_file_id, "error"}
    ]

    Enum.each(files_to_delete, fn
      {nil, _type} ->
        :ok

      {file_id, type} ->
        # Fire-and-forget: spawn a process to delete the file
        spawn(fn ->
          case OpenaiApiClient.delete_file(file_id) do
            {:ok, _} ->
              Logger.info("Deleted OpenAI #{type} file #{file_id} for batch #{batch.id}")

            {:error, :not_found} ->
              Logger.debug("OpenAI #{type} file #{file_id} not found (may already be deleted)")

            {:error, error} ->
              Logger.warning("Failed to delete OpenAI #{type} file #{file_id}: #{inspect(error)}")
          end
        end)
    end)

    Logger.debug("Fired deletion requests for OpenAI files for batch #{batch.id}")
  end
end
