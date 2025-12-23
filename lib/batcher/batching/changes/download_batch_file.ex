defmodule Batcher.Batching.Changes.DownloadBatchFile do
  use Ash.Resource.Change
  require Logger

  alias Batcher.OpenaiApiClient

  @impl true
  def change(changeset, _opts, _context) do
    # We use `around_action` (or `after_action`) to do the work
    # effectively "inside" the action execution flow but allowing
    # us to control the result.

    Ash.Changeset.after_action(changeset, fn _changeset, batch ->
      Logger.info("Starting download for batch #{batch.id}")

      # 1. Download output file from OpenAI
      with {:ok, file_path} <- OpenaiApiClient.download_file(batch.openai_output_file_id),
           # 2. Process
           :ok <- process_results(batch.id, file_path) do
        # Cleanup
        File.rm(file_path)

        Logger.info("Completed download and processing for batch #{batch.id}")

        # Return success tuple. The batch state update happens
        # because of the `transition_state` in the action definition
        # (which technically runs 'before' this hook in terms of changeset setup,
        # but the DB commit happens after).
        {:ok, batch}
      else
        {:error, reason} ->
          Logger.error("Download failed: #{inspect(reason)}")
          {:error, reason}

        error ->
          {:error, error}
      end
    end)
  end

  defp process_results(batch_id, file_path) do
    try do
      Batcher.Repo.transaction(
        fn ->
          file_path
          |> File.stream!()
          |> Stream.map(&JSON.decode!/1)
          |> Stream.each(fn row -> update_request(batch_id, row) end)
          |> Stream.run()
        end,
        timeout: :infinity
      )

      :ok
    rescue
      e -> {:error, e}
    end
  end

  defp update_request(batch_id, %{"custom_id" => custom_id, "response" => response}) do
    # Extract the actual body (response map)
    # response structure is usually: {"status_code": 200, "body": {...}}
    response_payload = response["body"]

    # We use a bulk update (atomic) if possible, but since we are iterating
    # line by line with specific payloads, we need individual updates.
    # To make this fast, we look up by the compound index [batch_id, custom_id].

    case Batcher.Batching.get_request_by_custom_id(batch_id, custom_id) do
      {:ok, request} ->
        # Perform the update
        request
        |> Ash.Changeset.for_update(:complete_processing, %{response_payload: response_payload})
        |> Ash.update!()

      _ ->
        Logger.warning("Batch #{batch_id}: Found result for unknown custom_id: #{custom_id}")
    end
  end

  # Helper to handle errors if the structure of the JSONL line is unexpected
  defp update_request(batch_id, data) do
    Logger.error("Batch #{batch_id}: Unexpected JSONL line format: #{inspect(data)}")
  end
end
