defmodule Batcher.Batching.Changes.CreateDeliveryAttempt do
  @moduledoc """
  Records delivery attempts in the audit log for requests.

  This change automatically creates a delivery attempt record when a request
  is delivered (successfully or with failure). It reads delivery attempt info
  from the changeset context, which should be set by the calling code.
  """
  use Ash.Resource.Change

  alias Batcher.Batching

  @impl true
  @doc false
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn cs, result ->
      create_attempt_from_changeset(cs, result)
    end)
  end

  defp create_attempt_from_changeset(cs, result) do
    outcome = get_in(cs.context, [:delivery_attempt, :outcome])
    error_msg = get_in(cs.context, [:delivery_attempt, :error_msg])

    attempt_number =
      get_in(cs.context, [:delivery_attempt, :attempt_number]) ||
        (result.delivery_attempt_count || 0) + 1

    if outcome != nil do
      params = %{
        request_id: result.id,
        attempt_number: attempt_number,
        delivery_config: result.delivery_config,
        outcome: outcome,
        error_msg: error_msg
      }

      case Ash.create(Batching.RequestDeliveryAttempt, params) do
        {:ok, _} -> {:ok, result}
        {:error, err} -> {:error, err}
      end
    else
      {:ok, result}
    end
  end
end
