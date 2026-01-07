defmodule Batcher.Batching.Changes.PublishStateChange do
  @moduledoc """
  Publishes a PubSub notification when a batch state changes.

  This allows the BatchBuilder GenServer to be notified when the batch
  transitions out of the :building state so it can shut down properly.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    state_attribute = :state

    if Ash.Resource.Info.attribute(changeset.resource, state_attribute) == nil do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn cs, result ->
        case cs.action_type do
          :update ->
            from = Map.get(cs.data, state_attribute)
            to = Map.get(result, state_attribute)

            if from != to do
              # Publish state change notification
              BatcherWeb.Endpoint.broadcast(
                "batches:state_changed:#{result.id}",
                "state_changed",
                %{data: result}
              )
            end

            {:ok, result}

          _ ->
            {:ok, result}
        end
      end)
    end
  end
end
