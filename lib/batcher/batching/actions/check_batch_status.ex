defmodule Batcher.Batching.Actions.CheckBatchStatus do
  require Logger
  alias Batcher.OpenaiApiClient
  alias Batcher.Batching
  alias Batcher.Batching.Utils

  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)

    batch = Batching.get_batch_by_id!(batch_id)

    case OpenaiApiClient.check_batch_status(batch.openai_batch_id) do
      {:ok, %{"status" => "completed"} = response} ->
        Logger.info("Batch #{batch.id} processing completed on OpenAI")
        usage = OpenaiApiClient.extract_token_usage_from_batch_status(response)
        expires_at_data = parse_expires_at(response, batch)

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
            expires_at_data
          )
        )
        |> Ash.update()

      {:ok, %{"status" => status} = resp} when status in ["failed", "expired"] ->
        error_msg = JSON.encode!(resp)
        Logger.error("Batch #{batch.id} processing #{status} on OpenAI: #{error_msg}")
        expires_at_data = parse_expires_at(resp, batch)

        batch
        |> Ash.Changeset.for_update(:failed, Map.merge(%{error_msg: error_msg}, expires_at_data))
        |> Ash.update()

      {:ok, pending_resp} ->
        status = Map.get(pending_resp, "status", "unknown")
        Logger.debug("Batch #{batch.id} still processing on OpenAI (status: #{status})")
        expires_at_data = parse_expires_at(pending_resp, batch)

        batch
        |> Ash.Changeset.for_update(:set_openai_status_last_checked, expires_at_data)
        |> Ash.update()

      {:error, reason} ->
        Logger.error(
          "Failed to get OpenAI batch status for batch #{batch.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp parse_expires_at(response, batch) do
    if is_nil(batch.expires_at) and response["expires_at"] do
      %{expires_at: DateTime.from_unix!(response["expires_at"])}
    else
      %{}
    end
  end
end
