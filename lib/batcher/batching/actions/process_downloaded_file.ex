defmodule Batcher.Batching.Actions.ProcessDownloadedFile do
  require Logger
  require Ash.Query

  alias Batcher.OpenaiApiClient
  alias Batcher.Batching

  def run(input, _opts, _context) do
    IO.inspect(input)
    batch_id = input.params["primary_key"]["id"]

    batch = Batching.get_batch_by_id!(batch_id)

    Logger.info("Starting download for batch #{batch.id}")

    # Download the file from OpenAI
    with {:ok, file_path} <- OpenaiApiClient.download_file(batch.openai_output_file_id),

         # Process it in chunks
         :ok <- process_results_in_chunks(batch.id, file_path) do
      File.rm(file_path)
      Logger.info("Batch #{batch.id} download and update of requests complete.")

      batch
      |> Ash.Changeset.for_update(:finalize_processing)
      |> Ash.update()
    else
      {:error, reason} ->
        Logger.error("Failed: #{inspect(reason)}")
        {:error, reason}

      error ->
        {:error, error}
    end
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

    # Fetch the corresponding requests at once
    requests =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch_id)
      |> Ash.Query.filter(custom_id in ^custom_ids)
      |> Ash.read!()

    # Build a map of requests by custom_id for quick lookup
    requests_map = Map.new(requests, &{&1.custom_id, &1})

    result = Batcher.Repo.transaction(fn ->
      Enum.each(chunk, fn row ->
        update_request(row, requests_map)
      end)
    end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
          request
          |> Ash.Changeset.for_update(:complete_processing, %{response_payload: response})
          |> Ash.update!()
        end
    end
  end

  # Catch-all for malformed lines
  defp update_request(_batch_id, _data), do: :ok
end
