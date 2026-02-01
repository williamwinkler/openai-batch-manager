defmodule Batcher.Batching.FileProcessing do
  @moduledoc """
  Shared file processing logic for downloading and processing OpenAI batch result files.

  Used by both ProcessDownloadedFile (normal completion) and ProcessExpiredBatch (partial expiration).
  """

  require Logger
  require Ash.Query

  alias Batcher.OpenaiApiClient
  alias Batcher.Batching

  @doc """
  Downloads a file from OpenAI and processes its JSONL contents, updating requests accordingly.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def process_file(batch_id, file_id, file_type) do
    Logger.info("Batch #{batch_id} downloading #{file_type} file: #{file_id}")

    with {:ok, file_path} <- OpenaiApiClient.download_file(file_id) do
      Logger.info("Batch #{batch_id} #{file_type} file downloaded successfully to #{file_path}")

      case process_results_in_chunks(batch_id, file_path, file_type) do
        :ok ->
          File.rm(file_path)
          Logger.info("Batch #{batch_id} #{file_type} file processed successfully")
          :ok

        {:error, reason} = error ->
          Logger.error(
            "Batch #{batch_id} failed to process #{file_type} file: #{inspect(reason)}"
          )

          error
      end
    else
      {:error, reason} ->
        Logger.error("Batch #{batch_id} failed to download #{file_type} file: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error(
          "Batch #{batch_id} #{file_type} file download returned unexpected value: #{inspect(other)}"
        )

        {:error, other}
    end
  end

  @doc """
  After file processing is complete, finalizes batch state based on request outcomes.

  Transitions batch to `ready_to_deliver` and then determines the appropriate final state
  based on whether all requests are in terminal states and their outcomes.

  Returns `{:ok, batch}` or `{:error, reason}`.
  """
  def finalize_and_determine_outcome(batch) do
    Logger.info(
      "Batch #{batch.id} download and processing complete, transitioning to ready_to_deliver"
    )

    {:ok, updated_batch} =
      batch
      |> Ash.Changeset.for_update(:finalize_processing)
      |> Ash.update()

    updated_batch =
      Ash.load!(updated_batch, [:requests_terminal_count, :request_count, :delivery_stats])

    if updated_batch.requests_terminal_count do
      total_count = updated_batch.request_count

      success_states = [:delivered, :delivery_failed, :openai_processed]

      success_count =
        Batching.Request
        |> Ash.Query.filter(batch_id == ^updated_batch.id)
        |> Ash.Query.filter(state in ^success_states)
        |> Ash.count!()

      cond do
        total_count == 0 ->
          Logger.info("Batch #{batch.id} has no requests, marking as delivered")

          updated_batch
          |> Ash.Changeset.for_update(:start_delivering)
          |> Ash.update!()
          |> Ash.Changeset.for_update(:mark_delivered)
          |> Ash.update()

        success_count > 0 ->
          %{delivered: delivered_count, failed: failed_count} = updated_batch.delivery_stats

          {action, state_name} =
            cond do
              delivered_count > 0 and failed_count == 0 ->
                {:mark_delivered, "delivered"}

              delivered_count == 0 and failed_count > 0 ->
                {:mark_delivery_failed, "delivery_failed"}

              delivered_count > 0 and failed_count > 0 ->
                {:mark_partially_delivered, "partially_delivered"}

              true ->
                {:mark_delivered, "delivered"}
            end

          Logger.info(
            "Batch #{batch.id} has all requests in terminal states, marking as #{state_name}"
          )

          updated_batch
          |> Ash.Changeset.for_update(:start_delivering)
          |> Ash.update!()
          |> Ash.Changeset.for_update(action)
          |> Ash.update()

        true ->
          Logger.info(
            "Batch #{batch.id} has all requests in terminal states but all failed at OpenAI, marking as failed"
          )

          updated_batch
          |> Ash.Changeset.for_update(:failed, %{error_msg: "All requests in batch failed"})
          |> Ash.update()
      end
    else
      {:ok, updated_batch}
    end
  end

  # Private functions

  defp process_results_in_chunks(batch_id, file_path, file_type) do
    Logger.info("Batch #{batch_id} starting to process results file in chunks")

    chunks_processed =
      file_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case JSON.decode(line) do
          {:ok, decoded} ->
            decoded

          {:error, _} ->
            Logger.warning(
              "Skipping malformed JSON line in batch #{batch_id}: #{String.slice(line, 0, 100)}"
            )

            nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      # Process 100 at a time
      |> Stream.chunk_every(100)
      |> Stream.with_index(1)
      |> Enum.reduce_while(0, fn {chunk, chunk_num}, acc ->
        Logger.debug("Batch #{batch_id} processing chunk #{chunk_num} (#{length(chunk)} items)")

        case process_chunk(batch_id, chunk, file_type) do
          :ok ->
            total = acc + length(chunk)

            if rem(chunk_num, 10) == 0 do
              Logger.info("Batch #{batch_id} processed #{total} requests so far")
            end

            {:cont, total}

          error ->
            Logger.error(
              "Batch #{batch_id} failed processing chunk #{chunk_num}: #{inspect(error)}"
            )

            {:halt, error}
        end
      end)

    case chunks_processed do
      {:error, _} = error ->
        error

      total ->
        Logger.info(
          "Batch #{batch_id} finished processing all chunks, total requests processed: #{total}"
        )

        :ok
    end
  end

  defp process_chunk(batch_id, chunk, file_type) do
    custom_ids = Enum.map(chunk, & &1["custom_id"])

    Logger.debug("Batch #{batch_id} fetching #{length(custom_ids)} requests for chunk")

    requests =
      Batching.Request
      |> Ash.Query.filter(batch_id == ^batch_id)
      |> Ash.Query.filter(custom_id in ^custom_ids)
      |> Ash.read!()

    requests_map = Map.new(requests, &{&1.custom_id, &1})

    missing_count = length(custom_ids) - map_size(requests_map)

    if missing_count > 0 do
      Logger.warning(
        "Batch #{batch_id} chunk has #{missing_count} custom_ids not found in database"
      )
    end

    result =
      Batcher.Repo.transaction(fn ->
        Enum.each(chunk, fn row ->
          update_request(row, requests_map, file_type)
        end)
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Batch #{batch_id} transaction failed for chunk: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_request(
         row_data = %{"custom_id" => custom_id, "response" => response, "error" => err},
         requests_map,
         file_type
       ) do
    case Map.get(requests_map, custom_id) do
      nil ->
        Logger.warning("Openai returned custom_id #{custom_id} which is not found in DB")
        :ok

      request ->
        terminal_states = [:delivered, :failed, :delivery_failed, :expired, :cancelled]

        if request.state in terminal_states do
          Logger.debug(
            "Skipping request #{request.id} (custom_id: #{custom_id}) - already in terminal state: #{request.state}"
          )

          :ok
        else
          cond do
            file_type == "error" ->
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            file_type == "output" and not is_nil(err) ->
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            file_type == "output" and
                (is_map(response) and
                   (Map.get(response, "status_code") != 200 or
                      get_in(response, ["body", "error"]) != nil)) ->
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            file_type == "output" ->
              if request.state == :openai_processed do
                Logger.debug(
                  "Skipping request #{request.id} (custom_id: #{custom_id}) - already processed"
                )

                :ok
              else
                request
                |> Ash.Changeset.for_update(:complete_processing, %{response_payload: row_data})
                |> Ash.update!()
              end

            true ->
              Logger.warning(
                "Unexpected file_type #{file_type} for request #{request.id}, treating as error"
              )

              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()
          end
        end
    end
  end

  # Catch-all for malformed lines
  defp update_request(_row_data, _requests_map, _file_type), do: :ok
end
