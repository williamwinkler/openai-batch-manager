defmodule Batcher.Batching.Changes.DownloadBatchFile do
  use Ash.Resource.Change
  require Logger
  alias Batcher.OpenaiApiClient

  @impl true
  def change(changeset, _opts, _context) do
    IO.puts("Starting DownloadBatchFile change")
    Ash.Changeset.around_action(changeset, fn changeset, _ ->
      # The data before the update
      batch = changeset.data

      Logger.info("Starting download for batch #{batch.id}")

      IO.puts("test")

      with {:ok, file_path} <- OpenaiApiClient.download_file(batch.openai_output_file_id),
           :ok <- process_results_in_chunks(batch.id, file_path) do
        IO.inspect(file_path, label: "DEBUG: Downloaded file path")
        # File.rm(file_path)
        Logger.info("Batch #{batch.id} download and update of requests complete.")

        changeset
      else
        {:error, reason} ->
          IO.puts("error")
          Logger.error("Download batch output and update requests failed: #{inspect(reason)}")

          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "Download/processing failed: #{inspect(reason)}"
          )

        _ ->
          IO.puts("unexpected error")
          Logger.error("Unexpected error during batch file download and processing.")

          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "Download/processing failed: unexpected error"
          )
      end
    end)
    IO.puts("Finished DownloadBatchFile change")

    changeset
  end

  defp process_results_in_chunks(batch_id, file_path) do
    file_path
    |> File.stream!()
    |> Stream.map(&JSON.decode!/1)
    # Process 100 at a time
    |> Stream.chunk_every(100)
    |> Enum.reduce_while(:ok, fn chunk, _acc ->
      case process_chunk(batch_id, chunk) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp process_chunk(batch_id, chunk) do
    # Extract custom_ids from the chunk
    custom_ids = Enum.map(chunk, & &1["custom_id"])

    IO.inspect(length(chunk), label: "DEBUG: Processing chunk of size")

    # Fetch the corresponding requests at once
    requests =
      Batcher.Batching.Request
      |> Ash.Query.filter(batch_id == ^batch_id)
      |> Ash.Query.filter(custom_id in ^custom_ids)
      |> Ash.read!()

    # Build a map of requests by custom_id for quick lookup
    requests_map = Map.new(requests, &{&1.custom_id, &1})

    Batcher.Repo.transaction(fn ->
      Enum.each(chunk, fn row ->
        update_request(row, requests_map)
      end)
    end)
  end

  defp update_request(
         %{"custom_id" => custom_id, "response" => response, "error" => err},
         requests_map
       ) do
    case Map.get(requests_map, custom_id) do
      nil ->
        Logger.warning("Openai returned custom_id #{custom_id} which is not found in DB")
        :ok

      request ->
        if err do
          request
          |> Ash.Changeset.for_update(:mark_failed, %{error_msg: err})
          |> Ash.update!()
        else
          IO.puts("updating request #{custom_id} with response")
          request
          |> Ash.Changeset.for_update(:complete_processing, %{response_payload: response})
          |> Ash.update!()
        end
    end
  end

  # Catch-all for malformed lines
  defp update_request(_batch_id, _data), do: :ok
end
