defmodule BatcherWeb.Schemas.PromptResponseSchema do
  @moduledoc """
  OpenAPI schema for successful prompt creation response.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    type: :object,
    description: "Successful prompt creation response",
    required: [:data],
    properties: %{
      custom_id: %Schema{
        type: :string,
        description: "Unique identifier for the created prompt",
        example: "7edb3b2e-869c-485b-af70-76a934e0fcfd"
      }
    },
    example: %{
      "custom_id" => "7edb3b2e-869c-485b-af70-76a934e0fcfd"
    }
  })
end
