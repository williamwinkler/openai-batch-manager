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
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn cs, result ->
      create_attempt_from_changeset(cs, result)
    end)
  end

  defp create_attempt_from_changeset(cs, result) do
    # Get delivery attempt data from changeset context
    delivery_type = Ash.Changeset.get_attribute(cs, :delivery_type) || result.delivery_type
    success = get_in(cs.context, [:delivery_attempt, :success])
    error_msg = get_in(cs.context, [:delivery_attempt, :error_msg])

    if success != nil do
      params = %{
        request_id: result.id,
        type: delivery_type,
        success: success,
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
