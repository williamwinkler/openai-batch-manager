defmodule Batcher.Batching.Actions.CheckBatchStatus do
  require Logger
  alias Batcher.OpenaiApiClient
  alias Batcher.Batching

  def run(input, _opts, _context) do
    batch_id =
      case Map.fetch(input, :subject) do
        {:ok, %{id: id}} -> id
        _ -> get_in(input.params, ["primary_key", "id"])
      end

    batch = Batching.get_batch_by_id!(batch_id)

    case OpenaiApiClient.check_batch_status(batch.openai_batch_id) do
      {:ok, %{"status" => "completed"} = response} ->
        Logger.info("Batch #{batch.id} processing completed on OpenAI")
        usage = OpenaiApiClient.extract_token_usage_from_batch_status(response)

        batch
        |> Ash.Changeset.for_update(:openai_processing_completed, %{
          openai_output_file_id: response["output_file_id"],
          openai_error_file_id: response["error_file_id"],
          input_tokens: usage.input_tokens,
          cached_tokens: usage.cached_tokens,
          reasoning_tokens: usage.reasoning_tokens,
          output_tokens: usage.output_tokens
        })
        |> Ash.update()

      {:ok, %{"status" => status} = resp} when status in ["failed", "expired"] ->
        error_msg = JSON.encode!(resp)
        Logger.error("Batch #{batch.id} processing #{status} on OpenAI: #{error_msg}")

        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update()

      {:ok, pending_resp} ->
        status = Map.get(pending_resp, "status", "unknown")
        Logger.debug("Batch #{batch.id} still processing on OpenAI (status: #{status})")

        batch
        |> Ash.Changeset.for_update(:set_openai_status_last_checked)
        |> Ash.update()

      {:error, reason} ->
        Logger.error(
          "Failed to get OpenAI batch status for batch #{batch.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
