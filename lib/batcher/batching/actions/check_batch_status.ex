defmodule Batcher.Batching.Actions.CheckBatchStatus do
  require Logger
  alias Batcher.OpenaiApiClient
  alias Batcher.Batching
  alias Batcher.Batching.Utils

  @max_token_limit_retries 5

  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)

    batch = Batching.get_batch_by_id!(batch_id)

    case OpenaiApiClient.check_batch_status(batch.openai_batch_id) do
      {:ok, %{"status" => "completed"} = response} ->
        Logger.info("Batch #{batch.id} processing completed on OpenAI")
        usage = OpenaiApiClient.extract_token_usage_from_batch_status(response)
        progress_attrs = extract_request_counts(response)

        batch
        |> Ash.Changeset.for_update(
          :openai_processing_completed,
          Map.merge(
            %{
              openai_output_file_id: response["output_file_id"],
              openai_error_file_id: response["error_file_id"],
              input_tokens: usage.input_tokens,
              cached_tokens: usage.cached_tokens,
              reasoning_tokens: usage.reasoning_tokens,
              output_tokens: usage.output_tokens
            },
            progress_attrs
          )
        )
        |> Ash.update()

      {:ok, %{"status" => "expired"} = response} ->
        output_file_id = response["output_file_id"]
        error_file_id = response["error_file_id"]

        if output_file_id || error_file_id do
          Logger.info("Batch #{batch.id} expired with partial results")

          batch
          |> Ash.Changeset.for_update(:handle_partial_expiration, %{
            openai_output_file_id: output_file_id,
            openai_error_file_id: error_file_id
          })
          |> Ash.update()
        else
          Logger.info("Batch #{batch.id} expired with no results, rescheduling")

          batch
          |> Ash.Changeset.for_update(:mark_expired, %{})
          |> Ash.update()
        end

      {:ok, %{"status" => "failed"} = resp} ->
        error_msg = JSON.encode!(resp)
        progress_attrs = extract_request_counts(resp)

        if token_limit_exceeded?(resp) do
          current_attempts = batch.token_limit_retry_attempts || 0

          if current_attempts < @max_token_limit_retries do
            Logger.warning(
              "Batch #{batch.id} hit OpenAI token_limit_exceeded (attempt #{current_attempts + 1}/#{@max_token_limit_retries}); requeueing with backoff"
            )

            batch
            |> Ash.Changeset.for_update(
              :handle_token_limit_exceeded,
              %{token_limit_retry_last_error: error_msg}
            )
            |> Ash.update()
          else
            Logger.error(
              "Batch #{batch.id} exhausted token_limit_exceeded retries (#{current_attempts}/#{@max_token_limit_retries}); failing permanently"
            )

            terminal_error =
              "OpenAI token limit retries exhausted after #{current_attempts} attempts. Last error: #{error_msg}"

            batch
            |> Ash.Changeset.for_update(
              :fail_token_limit_exhausted,
              %{error_msg: terminal_error}
            )
            |> Ash.update()
          end
        else
          Logger.error("Batch #{batch.id} processing failed on OpenAI: #{error_msg}")

          batch
          |> Ash.Changeset.for_update(:failed, Map.put(progress_attrs, :error_msg, error_msg))
          |> Ash.update()
        end

      {:ok, pending_resp} ->
        status = Map.get(pending_resp, "status", "unknown")
        Logger.debug("Batch #{batch.id} still processing on OpenAI (status: #{status})")
        progress_attrs = extract_request_counts(pending_resp)

        if request_counts_changed?(batch, progress_attrs) do
          batch
          |> Ash.Changeset.for_update(:record_openai_progress, progress_attrs)
          |> Ash.update()
        else
          batch
          |> Ash.Changeset.for_update(:set_openai_status_last_checked, %{})
          |> Ash.update()
        end

      {:error, reason} ->
        Logger.error(
          "Failed to get OpenAI batch status for batch #{batch.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp request_counts_changed?(_batch, attrs) when attrs == %{}, do: false

  defp request_counts_changed?(batch, attrs) do
    Enum.any?(attrs, fn {key, value} -> Map.get(batch, key) != value end)
  end

  defp extract_request_counts(%{"request_counts" => request_counts})
       when is_map(request_counts) do
    %{}
    |> maybe_put_integer(:openai_requests_completed, read_count(request_counts, "completed"))
    |> maybe_put_integer(:openai_requests_failed, read_count(request_counts, "failed"))
    |> maybe_put_integer(:openai_requests_total, read_count(request_counts, "total"))
  end

  defp extract_request_counts(_), do: %{}

  defp maybe_put_integer(attrs, _key, value) when not is_integer(value), do: attrs
  defp maybe_put_integer(attrs, _key, value) when value < 0, do: attrs
  defp maybe_put_integer(attrs, key, value), do: Map.put(attrs, key, value)

  defp read_count(request_counts, key) do
    case key do
      "completed" -> Map.get(request_counts, "completed") || Map.get(request_counts, :completed)
      "failed" -> Map.get(request_counts, "failed") || Map.get(request_counts, :failed)
      "total" -> Map.get(request_counts, "total") || Map.get(request_counts, :total)
    end
  end

  defp token_limit_exceeded?(body) when is_map(body) do
    errors = get_in(body, ["errors", "data"]) || []
    error = body["error"] || %{}

    Enum.any?(errors, fn row -> row["code"] == "token_limit_exceeded" end) or
      error["code"] == "token_limit_exceeded"
  end

  defp token_limit_exceeded?(_), do: false
end
