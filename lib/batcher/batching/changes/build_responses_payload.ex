defmodule Batcher.Batching.Changes.BuildResponsesPayload do
  @moduledoc """
  Builds the request_payload for /v1/responses endpoint from action arguments.

  Extracts all request parameters and stores them as a JSON map in the request_payload attribute.
  This payload will be used later to generate the JSONL file for batch upload.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Extract all request arguments
    payload = %{
      "model" => Ash.Changeset.get_argument(changeset, :model),
      "input" => Ash.Changeset.get_argument(changeset, :input)
    }

    # Add optional fields if present
    payload =
      payload
      |> add_if_present(changeset, :instructions)
      |> add_if_present(changeset, :temperature)
      |> add_if_present(changeset, :max_output_tokens)
      |> add_if_present(changeset, :top_p)
      |> add_if_present(changeset, :store)
      |> add_if_present(changeset, :text)
      |> add_if_present(changeset, :additional_params)

    # Set attributes on the changeset
    changeset
    |> Ash.Changeset.force_change_attribute(:request_payload, payload)
    |> Ash.Changeset.force_change_attribute(:endpoint, "/v1/responses")
    |> Ash.Changeset.force_change_attribute(:model, payload["model"])
  end

  defp add_if_present(payload, changeset, field) do
    case Ash.Changeset.get_argument(changeset, field) do
      nil -> payload
      value -> Map.put(payload, to_string(field), value)
    end
  end
end
