defmodule Batcher.Batching.Changes.AssignToBatch do
  @moduledoc """
  Assigns a prompt to a batch via the BatchBuilder GenServer.

  This change intercepts the create action and routes the prompt to the appropriate
  BatchBuilder based on url and model. The BatchBuilder will assign the batch_id
  and create the actual Prompt record via the :create_internal action.

  The normal create flow is bypassed - we return the prompt created by BatchBuilder.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    url = Ash.Changeset.get_attribute(changeset, :url)
    model = Ash.Changeset.get_attribute(changeset, :model)

    # Extract all prompt data from the changeset
    # Structure data the way BatchBuilder expects it
    request_payload = Ash.Changeset.get_attribute(changeset, :request_payload)

    # If request_payload is already a string (SetPayload ran), decode it
    request_payload_map =
      if is_binary(request_payload) do
        JSON.decode!(request_payload)
      else
        request_payload
      end

    # Extract body from request_payload or create it
    # Handle both string and atom keys - BatchBuilder expects atom keys
    body =
      case Map.get(request_payload_map, "body") || Map.get(request_payload_map, :body) do
        nil ->
          # No body in request_payload, create one with model
          %{model: model}

        body_map when is_map(body_map) ->
          # Access model from body, handling both string and atom keys
          body_model = Map.get(body_map, "model") || Map.get(body_map, :model) || model
          # Create body map with atom keys as BatchBuilder expects
          # Convert string keys to atoms safely
          body_map
          |> Enum.map(fn
            {k, v} when is_binary(k) ->
              atom_key =
                case k do
                  "model" ->
                    :model

                  "input" ->
                    :input

                  "temperature" ->
                    :temperature

                  "max_tokens" ->
                    :max_tokens

                  _ ->
                    # Only convert to atom if it already exists to avoid creating new atoms
                    try do
                      String.to_existing_atom(k)
                    rescue
                      ArgumentError -> k
                    end
                end

              {atom_key, v}

            {k, v} ->
              {k, v}
          end)
          |> Map.new()
          |> Map.put(:model, body_model)
      end

    # Build delivery map from argument (SetDeliveryConfig hasn't run yet)
    # Extract from delivery argument, handling both map and atom-keyed maps
    delivery_arg = Ash.Changeset.get_argument(changeset, :delivery) || %{}

    # Normalize delivery to have string keys
    delivery =
      delivery_arg
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {to_string(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.new()

    prompt_data = %{
      custom_id: Ash.Changeset.get_attribute(changeset, :custom_id),
      url: url,
      body: body,
      method:
        Map.get(request_payload_map, "method") || Map.get(request_payload_map, :method) || "POST",
      delivery: delivery,
      tag: Ash.Changeset.get_attribute(changeset, :tag)
    }

    # Add to batch via BatchBuilder GenServer
    case Batcher.BatchBuilder.add_request(url, model, prompt_data) do
      {:ok, prompt} ->
        # Return the created prompt (bypass normal create)
        Ash.Changeset.after_action(changeset, fn _cs, _result ->
          {:ok, prompt}
        end)

      {:error, :batch_full} ->
        # Retry once (will create new BatchBuilder for new batch)
        case Batcher.BatchBuilder.add_request(url, model, prompt_data) do
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
