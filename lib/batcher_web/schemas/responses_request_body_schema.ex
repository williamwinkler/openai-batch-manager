defmodule BatcherWeb.Schemas.ResponsesRequestBodySchema do
  @moduledoc """
  OpenAPI schema for /v1/responses endpoint request body (chat completions).
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.{DeliverySchema, MessageSchema}

  OpenApiSpex.schema(%{
    type: :object,
    description: "Request body for /v1/responses endpoint (chat completions/responses)",
    required: [:custom_id, :model, :endpoint, :input, :delivery],
    properties: %{
      custom_id: %Schema{
        type: :string,
        description: "Unique identifier for this request (used to match request with response)",
        example: "7edb3b2e-869c-485b-af70-76a934e0fcfd"
      },
      model: %Schema{
        type: :string,
        description: "OpenAI model to use (e.g., 'gpt-4o-mini', 'gpt-4.1')",
        example: "gpt-4o-mini"
      },
      endpoint: %Schema{
        type: :string,
        enum: ["/v1/responses"],
        description: "Must be '/v1/responses' for this request type"
      },
      input: %Schema{
        oneOf: [
          %Schema{
            type: :string,
            description: "Plain text input",
            example: "Explain quantum computing in simple terms"
          },
          %Schema{
            type: :array,
            description: "Conversation messages",
            items: MessageSchema,
            example: [
              %{"role" => "developer", "content" => "You are a helpful assistant"},
              %{"role" => "user", "content" => "Hello!"}
            ]
          }
        ],
        description:
          "Input text (string) or conversation messages (array of message objects with 'role' and 'content')"
      },
      delivery: DeliverySchema,
      instructions: %Schema{
        type: :string,
        description: "System instructions for the model",
        example: "You are a helpful assistant"
      },
      temperature: %Schema{
        type: :number,
        format: :float,
        minimum: 0,
        maximum: 2,
        description: "Sampling temperature (0-2). Higher values make output more random",
        example: 0.7
      },
      max_output_tokens: %Schema{
        type: :integer,
        minimum: 1,
        description: "Maximum number of tokens to generate in the response",
        example: 500
      },
      top_p: %Schema{
        type: :number,
        format: :float,
        minimum: 0,
        maximum: 1,
        description: "Nucleus sampling parameter (0-1). Alternative to temperature",
        example: 0.9
      },
      store: %Schema{
        type: :boolean,
        default: true,
        description: "Whether to store the response for later retrieval via API (default: true)"
      }
    },
    example: %{
      "custom_id" => Ecto.UUID.generate(),
      "model" => "gpt-4o-mini",
      "endpoint" => "/v1/responses",
      "input" => [
        %{"role" => "developer", "content" => "You are a helpful assistant"},
        %{"role" => "user", "content" => "Hello!"}
      ],
      "temperature" => 0.7,
      "max_output_tokens" => 500,
      "delivery" => %{
        "type" => "webhook",
        "webhook_url" => "https://api.example.com/webhook?auth=secret"
      }
    }
  })
end
