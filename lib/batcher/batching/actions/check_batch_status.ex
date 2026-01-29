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

        batch
        |> Ash.Changeset.for_update(
          :openai_processing_completed,
          %{
            openai_output_file_id: response["output_file_id"],
            openai_error_file_id: response["error_file_id"],
            input_tokens: usage.input_tokens,
            cached_tokens: usage.cached_tokens,
            reasoning_tokens: usage.reasoning_tokens,
            output_tokens: usage.output_tokens
          }
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
        Logger.error("Batch #{batch.id} processing failed on OpenAI: #{error_msg}")

        batch
        |> Ash.Changeset.for_update(:failed, %{error_msg: error_msg})
        |> Ash.update()

      {:ok, pending_resp} ->
        status = Map.get(pending_resp, "status", "unknown")
        Logger.debug("Batch #{batch.id} still processing on OpenAI (status: #{status})")

        batch
        |> Ash.Changeset.for_update(:set_openai_status_last_checked, %{})
        |> Ash.update()

      {:error, reason} ->
        Logger.error(
          "Failed to get OpenAI batch status for batch #{batch.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
