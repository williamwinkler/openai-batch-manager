defmodule Batcher.Batching.Changes.SetPayload do
  use Ash.Resource.Change

  @doc """
  Sets and validates the request payload for a Request.
  We need to ensure that certain top-level fields in the payload
  match the attributes on the Request resource itself.

  Then we need to remove properties that shouldn't be in the batch once
  the request_payload is send to OpenAI batch API.

  These incluede:
    - delivery config
    - batch_id
  """
  @impl true
  @spec change(Ash.Changeset.t(), Keyword.t(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    custom_id = Ash.Changeset.get_attribute(changeset, :custom_id)
    model = Ash.Changeset.get_attribute(changeset, :model)
    url = Ash.Changeset.get_attribute(changeset, :url)

    request_payload = Ash.Changeset.get_argument(changeset, :request_payload)

    changeset
    |> validate_match(:custom_id, custom_id, request_payload.custom_id)
    |> validate_match(:model, model, request_payload.body.model)
    |> validate_match(:url, url, request_payload.url)
    |> set_json_payload(request_payload)
  end

  defp validate_match(changeset, field, value, payload_value) do
    if value != payload_value do
      Ash.Changeset.add_error(
        changeset,
        field: field,
        message:
          "does not match the value in request_payload: expected #{inspect(value)}, got #{inspect(payload_value)}"
      )
    else
      changeset
    end
  end

  defp set_json_payload(changeset, request_payload) do
    if changeset.valid? do
      # Remove delivery and batch_id before encoding to JSON
      request_payload_json =
        request_payload
        |> Map.delete(:delivery)
        |> Map.delete(:batch_id)
        |> JSON.encode!()

      changeset
      |> Ash.Changeset.force_change_attribute(:request_payload, request_payload_json)
      |> Ash.Changeset.force_change_attribute(
        :request_payload_size,
        byte_size(request_payload_json)
      )
    else
      changeset
    end
  end
end
