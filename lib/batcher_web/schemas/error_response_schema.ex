defmodule BatcherWeb.Schemas.ErrorResponseSchema do
  @moduledoc """
  OpenAPI schema for error responses.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    type: :object,
    description: "Error response",
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :array,
        description: "List of errors",
        items: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, description: "Error code", example: "required"},
            title: %Schema{type: :string, description: "Error title", example: "is required"},
            detail: %Schema{type: :string, description: "Detailed error message", example: "custom_id is required"},
            source: %Schema{
              type: :object,
              properties: %{
                pointer: %Schema{
                  type: :string,
                  description: "JSON pointer to the field that caused the error",
                  example: "/data/attributes/custom_id"
                }
              }
            }
          }
        }
      }
    },
    example: %{
      "errors" => [
        %{
          "code" => "required",
          "title" => "is required",
          "detail" => "custom_id is required",
          "source" => %{
            "pointer" => "/custom_id"
          }
        }
      ]
    }
  })
end
