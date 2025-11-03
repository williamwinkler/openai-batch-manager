defmodule Batcher.Batching.Validations.ValidateEndpointSupported do
  @moduledoc """
  Validates that the endpoint is currently supported.

  Currently supported endpoints:
  - /v1/responses (Chat completions / Responses API)
  - /v1/embeddings (Embeddings API)
  - /v1/moderations (Moderation API)
  """
  use Ash.Resource.Validation

  @supported_endpoints ["/v1/responses", "/v1/embeddings", "/v1/moderations"]

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
