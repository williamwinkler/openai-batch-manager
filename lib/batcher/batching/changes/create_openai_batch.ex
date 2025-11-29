defmodule Batcher.Batching.Changes.CreateOpenaiBatch do
  use Ash.Resource.Change
  require Logger

  alias Batcher.{OpenaiApiClient}

  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data

    Logger.info("Creating OpenAI batch for batch #{batch.id} (#{batch.url} - #{batch.model})")

    try do
      case OpenaiApiClient.create_batch(batch.openai_file_id, batch.url) do
        {:ok, response} ->
          openai_batch_id = response["id"]
          Logger.info("OpenAI batch created successfully (OpenAI Batch ID: #{openai_batch_id})")
          Ash.Changeset.force_change_attribute(changeset, :openai_batch_id, openai_batch_id)

        {:error, reason} ->
          Logger.error("OpenAI batch creation failed: #{inspect(reason)}")

          # Cleanup any existing batch and clear from changeset
          cleanup_existing_batch(changeset)

          Ash.Changeset.add_error(changeset, "OpenAI batch creation failed: #{reason}")
      end
    rescue
      error ->
        Logger.error("OpenAI batch creation crashed: #{inspect(error)}")

        # Cleanup any existing batch and clear from changeset
        cleanup_existing_batch(changeset)

        Ash.Changeset.add_error(changeset, "OpenAI batch creation crashed: #{inspect(error)}")
    end
  end

  defp cleanup_existing_batch(changeset) do
    case Ash.Changeset.get_attribute(changeset, :openai_batch_id) do
      nil ->
        changeset

      "" ->
        changeset

      batch_id ->
        Logger.info("Cleaning up existing OpenAI batch: #{batch_id}")

        case OpenaiApiClient.cancel_batch(batch_id) do
          {:ok, _} ->
            Logger.info("Successfully canceled OpenAI batch: #{batch_id}")
            # Remove the batch_id from changeset
            Ash.Changeset.force_change_attribute(changeset, :openai_batch_id, nil)

          {:error, reason} ->
            Logger.error("Failed to cancel OpenAI batch #{batch_id}: #{reason}")
            changeset
        end
    end
  end
end
