defmodule BatcherWeb.Schemas.ModerationRequestBodySchema do
  @moduledoc """
  OpenAPI schema for /v1/moderations endpoint request body (content moderation).
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.DeliverySchema

  OpenApiSpex.schema(%{
    type: :object,
    description: "Request body for /v1/moderations endpoint (content moderation)",
    required: [:custom_id, :model, :endpoint, :input, :delivery],
    properties: %{
      custom_id: %Schema{
        type: :string,
        description: "Unique identifier for this request (used to match request with response)",
        example: "7edb3b2e-869c-485b-af70-76a934e0fcfd"
      },
      model: %Schema{
        type: :string,
        description: "OpenAI moderation model to use (e.g., 'omni-moderation-latest', 'text-moderation-latest')",
        example: "omni-moderation-latest"
      },
      endpoint: %Schema{
        type: :string,
        enum: ["/v1/moderations"],
        description: "Must be '/v1/moderations' for this request type"
      },
      input: %Schema{
        oneOf: [
          %Schema{
            type: :string,
            description: "Single text to moderate",
            example: "This is some user-generated content to check"
          },
          %Schema{
            type: :array,
            description: "Multiple texts to moderate",
            items: %Schema{type: :string},
            example: ["First comment", "Second comment", "Third comment"]
          }
        ],
        description: "Input text to moderate - can be a single string or an array of strings"
      },
      delivery: DeliverySchema
    },
    example: %{
      "custom_id" => Ecto.UUID.generate(),
      "model" => "omni-moderation-latest",
      "endpoint" => "/v1/moderations",
      "input" => "This is some user-generated content to check",
      "delivery" => %{
        "type" => "webhook",
        "webhook_url" => "https://api.example.com/moderation-results"
      }
    }
  })
end
