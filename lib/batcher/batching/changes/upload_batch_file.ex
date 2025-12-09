defmodule Batcher.Batching.Changes.UploadBatchFile do
  use Ash.Resource.Change
  require Logger

  alias Batcher.{OpenaiApiClient}

  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data

    Logger.info("Processing batch #{batch.id}: building and uploading file")

    batches_dir = Application.get_env(:batcher, :batches_dir, "./data/batches")
    batch_file_path = Path.join(batches_dir, "batch_#{batch.id}.jsonl")

    try do
      with :ok <- build_batch_file(batch_file_path, batch),
           {:ok, openai_input_file_id} <- upload_file(batch_file_path) do
        cleanup_file(batch_file_path)
        Logger.info("Batch #{batch.id} uploaded successfully (OpenAI File ID: #{openai_input_file_id})")
        Ash.Changeset.force_change_attribute(changeset, :openai_input_file_id, openai_input_file_id)
      else
        {:error, reason} ->
          Logger.error("Batch #{batch.id} upload failed: #{inspect(reason)}")
          Ash.Changeset.add_error(changeset, "Batch upload failed: #{reason}")
      end
    rescue
      error ->
        Logger.error("Batch #{batch.id} upload crashed: #{inspect(error)}")
        cleanup_file(batch_file_path)
        changeset = cleanup_existing_openai_file(changeset)
        Ash.Changeset.add_error(changeset, "Upload crashed: #{inspect(error)}")
    end
  end

  defp build_batch_file(batch_file_path, batch) do
    File.mkdir_p!(Path.dirname(batch_file_path))
    Logger.debug("Started building #{Path.basename(batch_file_path)}")

    file = File.open!(batch_file_path, [:write])

    try do
      Batcher.Batching.Request
      |> Ash.Query.filter(batch_id: batch.id)
      |> Ash.Query.select([:request_payload])
      |> Ash.stream!(batch_size: 100)
      |> Stream.each(&IO.write(file, &1.request_payload <> "\n"))
      |> Stream.run()
    after
      File.close(file)
    end

    Logger.debug("Finished building batch_#{batch.id}.jsonl")
    :ok
  end

  defp cleanup_existing_openai_file(changeset) do
    case Ash.Changeset.get_attribute(changeset, :openai_input_file_id) do
      nil ->
        changeset

      file_id ->
        Logger.info("Cleaning up existing OpenAI file: #{file_id}")

        case OpenaiApiClient.delete_file(file_id) do
          {:ok, _} ->
            Logger.info("Successfully deleted OpenAI file: #{file_id}")
            # Remove the file_id from changeset
            Ash.Changeset.force_change_attribute(changeset, :openai_input_file_id, nil)

          {:error, reason} ->
            Logger.error("Failed to delete OpenAI file #{file_id}: #{reason}")
            changeset
        end
    end
  end

  defp upload_file(file_path) do
    case OpenaiApiClient.upload_file(file_path) do
      {:ok, response} -> {:ok, response["id"]}
      {:error, reason} -> {:error, "File upload failed: #{inspect(reason)}"}
    end
  end

  defp cleanup_file(file_path) do
    File.rm(file_path)
  end
end
