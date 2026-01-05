defmodule Batcher.Batching.Actions.CheckBatchStatus do
  require Logger
  alias Batcher.OpenaiApiClient
  alias Batcher.Batching

  def run(input, _opts, _context) do
    batch_id =
      case input.subject do
        %{id: id} -> id
        _ -> get_in(input.params, ["primary_key", "id"])
      end

    batch = Batching.get_batch_by_id!(batch_id)

    Logger.info("Checking OpenAI batch status for batch #{batch.id}")

    case OpenaiApiClient.check_batch_status(batch.openai_batch_id) do
      {:ok, %{"status" => "completed"} = response} ->
        Logger.info("Batch #{batch.id} processing completed on OpenAI.")
        usage = OpenaiApiClient.extract_token_usage_from_batch_status(response)

        batch
        |> Ash.Changeset.for_update(:openai_processing_completed, %{
          openai_output_file_id: response["output_file_id"],
          input_tokens: usage.input_tokens,
          cached_tokens: usage.cached_tokens,
          reasoning_tokens: usage.reasoning_tokens,
          output_tokens: usage.output_tokens
        })
        |> Ash.update()

      {:ok, %{"status" => status} = resp} when status in ["failed", "expired"] ->
        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: JSON.encode!(resp)})
        |> Ash.update()

      {:ok, _pending_resp} ->
        Logger.info("Batch #{batch.id} is still processing on OpenAI; no state change.")

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
