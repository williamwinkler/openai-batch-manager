defmodule Batcher.Batching.Changes.AssignToBatch do
  @moduledoc """
  Assigns a prompt to a batch via the BatchBuilder GenServer.

  This change intercepts the create action and routes the prompt to the appropriate
  BatchBuilder based on endpoint and model. The BatchBuilder will assign the batch_id
  and create the actual Prompt record via the :create_internal action.

  The normal create flow is bypassed - we return the prompt created by BatchBuilder.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)
    model = Ash.Changeset.get_attribute(changeset, :model)

    # Extract all prompt data from the changeset
    prompt_data = %{
      custom_id: Ash.Changeset.get_attribute(changeset, :custom_id),
      endpoint: endpoint,
      model: model,
      request_payload: Ash.Changeset.get_attribute(changeset, :request_payload),
      delivery_type: Ash.Changeset.get_attribute(changeset, :delivery_type),
      webhook_url: Ash.Changeset.get_attribute(changeset, :webhook_url),
      rabbitmq_queue: Ash.Changeset.get_attribute(changeset, :rabbitmq_queue),
      tag: Ash.Changeset.get_attribute(changeset, :tag)
    }

    # Add to batch via BatchBuilder GenServer
    case Batcher.BatchBuilder.add_prompt(endpoint, model, prompt_data) do
      {:ok, prompt} ->
        # Return the created prompt (bypass normal create)
        Ash.Changeset.after_action(changeset, fn _cs, _result ->
          {:ok, prompt}
        end)

      {:error, :batch_full} ->
        # Retry once (will create new BatchBuilder for new batch)
        case Batcher.BatchBuilder.add_prompt(endpoint, model, prompt_data) do
          {:ok, prompt} ->
            Ash.Changeset.after_action(changeset, fn _cs, _result ->
              {:ok, prompt}
            end)

          error ->
            Ash.Changeset.add_error(changeset, "Failed to assign to batch: #{inspect(error)}")
        end

      error ->
        Ash.Changeset.add_error(changeset, "Failed to assign to batch: #{inspect(error)}")
    end
  end
end
