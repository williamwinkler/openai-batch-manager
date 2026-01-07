defmodule Batcher.Batching.Actions.ProcessDownloadedFile do
  require Logger
  require Ash.Query

  alias Batcher.OpenaiApiClient
  alias Batcher.Batching

  def run(input, _opts, _context) do
    batch_id =
      case Map.fetch(input, :subject) do
        {:ok, %{id: id}} -> id
        _ -> get_in(input.params, ["primary_key", "id"])
      end

    batch = Batching.get_batch_by_id!(batch_id)

    Logger.info("Starting download for batch #{batch.id} (OpenAI file ID: #{batch.openai_output_file_id})")

    # Download the file from OpenAI
    with {:ok, file_path} <- OpenaiApiClient.download_file(batch.openai_output_file_id) do
      Logger.info("Batch #{batch.id} file downloaded successfully to #{file_path}")

      # Process it in chunks
      case process_results_in_chunks(batch.id, file_path) do
        :ok ->
          File.rm(file_path)
          Logger.info("Batch #{batch.id} download and processing complete, transitioning to ready_to_deliver")

          batch
          |> Ash.Changeset.for_update(:finalize_processing)
          |> Ash.update()

        {:error, reason} = error ->
          Logger.error("Batch #{batch.id} failed to process downloaded file: #{inspect(reason)}")
          error
      end
    else
      {:error, reason} ->
        Logger.error("Batch #{batch.id} failed to download file from OpenAI: #{inspect(reason)}")
        {:error, reason}

      error ->
        Logger.error("Batch #{batch.id} download crashed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp process_results_in_chunks(batch_id, file_path) do
    Logger.info("Batch #{batch_id} starting to process results file in chunks")

    chunks_processed =
      file_path
      |> File.stream!()
      |> Stream.map(&JSON.decode!/1)
      # Process 100 at a time
      |> Stream.chunk_every(100)
      |> Stream.with_index(1)
      |> Enum.reduce_while(0, fn {chunk, chunk_num}, acc ->
        Logger.debug("Batch #{batch_id} processing chunk #{chunk_num} (#{length(chunk)} items)")

        case process_chunk(batch_id, chunk) do
          :ok ->
            total = acc + length(chunk)
            if rem(chunk_num, 10) == 0 do
              Logger.info("Batch #{batch_id} processed #{total} requests so far")
            end
            {:cont, total}

          error ->
            Logger.error("Batch #{batch_id} failed processing chunk #{chunk_num}: #{inspect(error)}")
            {:halt, error}
        end
      end)

    case chunks_processed do
      {:error, _} = error ->
        error

      total ->
        Logger.info("Batch #{batch_id} finished processing all chunks, total requests processed: #{total}")
        :ok
    end
  end

  defp process_chunk(batch_id, chunk) do
    # Extract custom_ids from the chunk
    custom_ids = Enum.map(chunk, & &1["custom_id"])

    Logger.debug("Batch #{batch_id} fetching #{length(custom_ids)} requests for chunk")

    # Fetch the corresponding requests at once
    requests =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch_id)
      |> Ash.Query.filter(custom_id in ^custom_ids)
      |> Ash.read!()

    # Build a map of requests by custom_id for quick lookup
    requests_map = Map.new(requests, &{&1.custom_id, &1})

    missing_count = length(custom_ids) - map_size(requests_map)
    if missing_count > 0 do
      Logger.warning("Batch #{batch_id} chunk has #{missing_count} custom_ids not found in database")
    end

    result =
      Batcher.Repo.transaction(fn ->
        Enum.each(chunk, fn row ->
          update_request(row, requests_map)
        end)
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("Batch #{batch_id} transaction failed for chunk: #{inspect(reason)}")
        {:error, reason}
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
