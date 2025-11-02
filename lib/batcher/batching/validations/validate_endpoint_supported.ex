defmodule Batcher.Batching.Validations.ValidateEndpointSupported do
  @moduledoc """
  Validates that the endpoint is currently supported.

  For MVP, only /v1/responses is supported.
  """
  use Ash.Resource.Validation

  @supported_endpoints ["/v1/responses"]

  @impl true
  def validate(changeset, _opts, _context) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

    if endpoint in @supported_endpoints do
      :ok
    else
      {:error,
       field: :endpoint,
       message:
         "Endpoint #{endpoint} is not yet supported. Currently supported: #{inspect(@supported_endpoints)}"}
    end
  end
end
