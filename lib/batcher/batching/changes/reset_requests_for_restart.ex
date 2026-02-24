defmodule Batcher.Batching.Changes.ResetRequestsForRestart do
  @moduledoc """
  Runs an Ash change callback for batch lifecycle updates.
  """
  use Ash.Resource.Change
  require Ash.Query

  alias Batcher.Batching.Request

  @restartable_request_states [
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
  @doc false
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      batch = changeset.data

      result =
        Request
        |> Ash.Query.filter(batch_id == ^batch.id and state in ^@restartable_request_states)
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
            "Failed to reset batch requests for restart: #{Exception.message(error)}"
          )

        %Ash.BulkResult{status: :error, errors: errors} ->
          error_text =
            errors
            |> Enum.map_join(", ", fn error ->
              if is_exception(error), do: Exception.message(error), else: inspect(error)
            end)

          Ash.Changeset.add_error(
            changeset,
            "Failed to reset batch requests for restart: #{error_text}"
          )
      end
    end)
  end
end
