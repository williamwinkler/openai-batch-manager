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
          process_file(batch.id, file_id, "output")
      end

    # Process error file if it exists
    error_result =
      case error_file_id do
        nil ->
          Logger.info("Batch #{batch.id} has no error file (all requests succeeded)")
          :ok

        file_id ->
          process_file(batch.id, file_id, "error")
      end

    # Both files must process successfully
    case {output_result, error_result, output_file_id, error_file_id} do
      {:ok, :ok, nil, error_file_id} when not is_nil(error_file_id) ->
        # No output file but error file exists - all requests failed
        Logger.info(
          "Batch #{batch.id} has no output file but has error file - all requests failed, transitioning to failed"
        )

        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: "All requests in batch failed"})
        |> Ash.update()

      {:ok, :ok, _, _} ->
        Logger.info(
          "Batch #{batch.id} download and processing complete, transitioning to ready_to_deliver"
        )

        {:ok, updated_batch} =
          batch
          |> Ash.Changeset.for_update(:finalize_processing)
          |> Ash.update()

        # Check if all requests are already in terminal states (e.g., all failed at OpenAI)
        # If so, we need to determine the final batch state:
        # - If ALL requests failed → batch goes to :failed
        # - If at least some succeeded (delivered/delivery_failed) → batch goes to :done
        updated_batch = Ash.load!(updated_batch, [:requests_terminal_count, :request_count])

        if updated_batch.requests_terminal_count do
          # Count total requests and requests in "success" states
          total_count = updated_batch.request_count

          # Success states = requests that OpenAI processed successfully
          success_states = [:delivered, :delivery_failed, :openai_processed]

          success_count =
            Batching.Request
            |> Ash.Query.filter(batch_id == ^updated_batch.id)
            |> Ash.Query.filter(state in ^success_states)
            |> Ash.count!()

          cond do
            total_count == 0 ->
              # Edge case: batch has no requests - just mark as done
              Logger.info("Batch #{batch.id} has no requests, marking as done")

              updated_batch
              |> Ash.Changeset.for_update(:start_delivering)
              |> Ash.update!()
              |> Ash.Changeset.for_update(:done)
              |> Ash.update()

            success_count > 0 ->
              # At least some requests succeeded - batch is done
              Logger.info(
                "Batch #{batch.id} has all requests in terminal states with #{success_count} successes, marking as done"
              )

              updated_batch
              |> Ash.Changeset.for_update(:start_delivering)
              |> Ash.update!()
              |> Ash.Changeset.for_update(:done)
              |> Ash.update()

            true ->
              # All requests failed - batch should be marked as failed
              Logger.info(
                "Batch #{batch.id} has all requests in terminal states but all failed, marking as failed"
              )

              updated_batch
              |> Ash.Changeset.for_update(:failed, %{error_msg: "All requests in batch failed"})
              |> Ash.update()
          end
        else
          {:ok, updated_batch}
        end

      {{:error, reason}, _, _, _} ->
        Logger.error("Batch #{batch.id} failed to process output file: #{inspect(reason)}")
        {:error, reason}

      {_, {:error, reason}, _, _} ->
        Logger.error("Batch #{batch.id} failed to process error file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_file(batch_id, file_id, file_type) do
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

      error ->
        Logger.error("Batch #{batch_id} #{file_type} file download crashed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp process_results_in_chunks(batch_id, file_path, file_type) do
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
        # Skip requests that are already in terminal states (can't be updated)
        terminal_states = [:delivered, :failed, :delivery_failed, :expired, :cancelled]

        if request.state in terminal_states do
          Logger.debug(
            "Skipping request #{request.id} (custom_id: #{custom_id}) - already in terminal state: #{request.state}"
          )

          :ok
        else
          cond do
            # Error file entries are always failures
            file_type == "error" ->
              # Store entire JSONL line as JSON string in error_msg
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            # Output file entries with top-level error
            file_type == "output" and not is_nil(err) ->
              # Store entire JSONL line as JSON string in error_msg
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            # Output file entries with error in response (status_code != 200 or body.error exists)
            file_type == "output" and
                (is_map(response) and
                   (Map.get(response, "status_code") != 200 or
                      get_in(response, ["body", "error"]) != nil)) ->
              # Store entire JSONL line as JSON string in error_msg
              error_msg = JSON.encode!(row_data)

              request
              |> Ash.Changeset.for_update(:mark_failed, %{error_msg: error_msg})
              |> Ash.update!()

            # Successful output file entries
            file_type == "output" ->
              # Skip if already processed (idempotency for retries)
              if request.state == :openai_processed do
                Logger.debug(
                  "Skipping request #{request.id} (custom_id: #{custom_id}) - already processed"
                )

                :ok
              else
                # Store entire JSONL line (not just response.body) in response_payload
                request
                |> Ash.Changeset.for_update(:complete_processing, %{response_payload: row_data})
                |> Ash.update!()
              end

            true ->
              # Fallback for unexpected file_type
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
