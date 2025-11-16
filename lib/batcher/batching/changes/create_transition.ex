defmodule Batcher.Batching.Changes.CreateTransition do
  @moduledoc """
  Records state transitions in the audit log for resources using AshStateMachine.

  This change automatically creates a transition record when a resource's state changes.
  It handles both initial state creation and subsequent state transitions.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _ctx) do
    transition_resource = Keyword.fetch!(opts, :transition_resource)
    parent_id_field = Keyword.fetch!(opts, :parent_id_field)
    state_attribute = Keyword.get(opts, :state_attribute, :status)

    if Ash.Resource.Info.attribute(changeset.resource, state_attribute) == nil do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn cs, result ->
        case cs.action_type do
          :create ->
            to = Map.get(result, state_attribute)
            params = %{parent_id_field => result.id, from: nil, to: to}

            case Ash.create(transition_resource, params) do
              {:ok, _} -> {:ok, result}
              {:error, err} -> {:error, err}
            end

          :update ->
            from = Map.get(cs.data, state_attribute)
            to = Ash.Changeset.get_attribute(cs, state_attribute)

            if from != to do
              params = %{parent_id_field => result.id, from: from, to: to}

              case Ash.create(transition_resource, params) do
                {:ok, _} -> {:ok, result}
                {:error, err} -> {:error, err}
              end
            else
              {:ok, result}
            end

          _ ->
            {:ok, result}
        end
      end)
    end
  end
end
