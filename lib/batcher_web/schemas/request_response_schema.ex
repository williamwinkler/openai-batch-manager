defmodule BatcherWeb.Schemas.RequestResponseSchema do
  @moduledoc """
  OpenAPI schema for successful prompt creation response.
  """
  require OpenApiSpex
  require Protocol
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    type: :object,
    description: "Successful request creation response",
    required: [:data],
    properties: %{
      custom_id: %Schema{
        type: :string,
        description: "Unique identifier for the created request",
        example: "7edb3b2e-869c-485b-af70-76a934e0fcfd"
      }
    }
  })

  # Derive JSON.Encoder for the struct created by OpenApiSpex
  Protocol.derive(JSON.Encoder, __MODULE__, only: [:custom_id])
end
