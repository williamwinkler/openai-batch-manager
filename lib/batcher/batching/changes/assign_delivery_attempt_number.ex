defmodule Batcher.Batching.Changes.AssignDeliveryAttemptNumber do
  @moduledoc """
  Assigns the next attempt number when one is not explicitly provided.
  """
  use Ash.Resource.Change

  alias Batcher.Repo
  alias Ecto.Adapters.SQL

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    if Ash.Changeset.get_attribute(changeset, :attempt_number) do
      changeset
    else
      request_id = Ash.Changeset.get_attribute(changeset, :request_id)

      if request_id do
        # Lock the request row so concurrent attempt creation serializes per request.
        # This keeps attempt numbers monotonic under heavy retry concurrency.
        next_attempt = next_attempt_number_for_request(request_id)

        Ash.Changeset.change_attribute(changeset, :attempt_number, next_attempt)
      else
        Ash.Changeset.add_error(changeset, field: :request_id, message: "is required")
      end
    end
  end

  defp next_attempt_number_for_request(request_id) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT delivery_attempt_count FROM requests WHERE id = $1 FOR UPDATE",
        [request_id]
      )

    case rows do
      [[current_count]] when is_integer(current_count) -> current_count + 1
      _ -> 1
    end
  end
end
