defmodule Batcher.Batching.Changes.ComputePayloadSize do
  @moduledoc """
  Computes the size of the request_payload in bytes and sets the request_payload_size attribute.

  This change automatically calculates the JSON-encoded size of the request_payload
  whenever it's provided or modified.

  ## Usage

      create :create do
        accept [:request_payload, ...]
        change ComputePayloadSize
      end
  """
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), any(), any()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    # Only compute size if request_payload is being changed
    if Ash.Changeset.changing_attribute?(changeset, :request_payload) do
      case Ash.Changeset.get_attribute(changeset, :request_payload) do
        nil ->
          changeset

        payload when is_map(payload) ->
          # Encode the payload to JSON and get byte size
          size = payload |> Jason.encode!() |> byte_size()

          # Set the computed size
          Ash.Changeset.force_change_attribute(changeset, :request_payload_size, size)

        _other ->
          changeset
      end
    else
      changeset
    end
  end
end
