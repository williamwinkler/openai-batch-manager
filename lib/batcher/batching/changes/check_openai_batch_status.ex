defmodule Batcher.Batching.Changes.CheckOpenaiBatchStatus do
  @moduledoc """
  Check the status of an OpenAI batch and update the batch state.

  - Reference: https://platform.openai.com/docs/guides/batch#4-check-the-status-of-a-batch

  Expected shape (successful "completed"):

      %{
        "id" => "batch_...",
        "status" => "completed",
        "endpoint" => "/v1/responses",
        "created_at" => 1764435445,
        "completed_at" => 1764436320,
        "request_counts" => %{"total" => 5, "completed" => 5, "failed" => 0},
        "output_file_id" => "file-...",
        "error_file_id" => nil,
        "usage" => %{
          "input_tokens" => 115,
          "output_tokens" => 10,
          "total_tokens" => 125
        }
      }

  Notes:
  - Only `"status"` is required for state transitions; other fields are logged/audited.
  - See function docs for details on how responses are mapped to states.
  """
  use Ash.Resource.Change
  require Logger

  alias Batcher.OpenaiApiClient

  @impl true
  def change(changeset, _opts, _ctx) do
    batch = changeset.data

    case OpenaiApiClient.check_batch_status(batch.openai_batch_id) do
      {:ok, %{"status" => status} = response} ->
        Logger.debug("OpenAI batch #{batch.id} status: #{status}")

        new_state = map_status_to_state(status)

        if new_state != batch.state do
          changeset
          |> update_batch_state(new_state, response)
          |> update_checked_at()
        else
          Logger.debug("OpenAI batch #{batch.id} is still processing; no state change.")
          changeset |> update_checked_at()
        end

      {:error, reason} ->
        Logger.error(
          "Failed to get OpenAI batch status for batch #{batch.id}: #{inspect(reason)}"
        )

        Ash.Changeset.add_error(
          changeset,
          "Failed to get OpenAI batch status: #{inspect(reason)}"
        )
    end
  end

  defp update_batch_state(changeset, :openai_completed, response) do
    usage_tokens = OpenaiApiClient.extract_token_usage_from_batch_status(response)

    Logger.info(
      "Batch #{changeset.data.id} completed successfully with request counts: #{inspect(response["request_count"])}"
    )

    changeset
    |> Ash.Changeset.change_attribute(:state, :openai_completed)
    |> Ash.Changeset.change_attribute(:openai_output_file_id, response["output_file_id"])
    |> Ash.Changeset.change_attribute(:input_tokens, usage_tokens.input_tokens)
    |> Ash.Changeset.change_attribute(:cached_tokens, usage_tokens.cached_tokens)
    |> Ash.Changeset.change_attribute(:reasoning_tokens, usage_tokens.reasoning_tokens)
    |> Ash.Changeset.change_attribute(:output_tokens, usage_tokens.output_tokens)
  end

  defp update_batch_state(changeset, :failed, response) do
    error_msg = response["errors"] |> JSON.encode!()

    Logger.info("Batch #{changeset.data.id} failed with errors: #{inspect(error_msg)}")

    changeset
    |> Ash.Changeset.change_attribute(:state, :failed)
    |> Ash.Changeset.change_attribute(:error_msg, error_msg)
  end

  defp update_batch_state(changeset, :cancelled, _response) do
    Logger.info("Batch #{changeset.data.id} was cancelled")

    changeset
    |> Ash.Changeset.change_attribute(:state, :cancelled)
  end

  defp map_status_to_state("validating"), do: :openai_processing
  defp map_status_to_state("in_progress"), do: :openai_processing
  defp map_status_to_state("finalizing"), do: :openai_processing
  defp map_status_to_state("completed"), do: :openai_completed
  defp map_status_to_state("failed"), do: :failed
  defp map_status_to_state("expired"), do: :failed
  defp map_status_to_state("cancelling"), do: :cancelled
  defp map_status_to_state("cancelled"), do: :cancelled

  defp update_checked_at(changeset) do
    changeset
    |> Ash.Changeset.change_attribute(:openai_status_last_checked_at, DateTime.utc_now())
  end
end
