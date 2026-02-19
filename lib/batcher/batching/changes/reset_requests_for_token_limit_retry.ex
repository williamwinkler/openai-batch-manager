defmodule Batcher.Batching.Changes.ResetRequestsForTokenLimitRetry do
  use Ash.Resource.Change
  require Ash.Query

  alias Batcher.Batching.Request

  @retry_resettable_states [
    :openai_processing,
    :openai_processed,
    :delivering,
    :delivered,
    :failed,
    :delivery_failed,
    :expired,
    :cancelled
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      batch = changeset.data

      result =
        Request
        |> Ash.Query.filter(batch_id == ^batch.id and state in ^@retry_resettable_states)
        |> Ash.bulk_update(
          :restart_to_pending,
          %{error_msg: nil, response_payload: nil},
          strategy: :stream
        )

      case result do
        %Ash.BulkResult{status: :success} ->
          changeset

        {:error, error} ->
          Ash.Changeset.add_error(
            changeset,
            "Failed to reset requests for token-limit retry: #{Exception.message(error)}"
          )

        %Ash.BulkResult{status: :error, errors: errors} ->
          messages =
            Enum.map_join(errors, ", ", fn error ->
              if is_exception(error), do: Exception.message(error), else: inspect(error)
            end)

          Ash.Changeset.add_error(
            changeset,
            "Failed to reset requests for token-limit retry: #{messages}"
          )
      end
    end)
  end
end
