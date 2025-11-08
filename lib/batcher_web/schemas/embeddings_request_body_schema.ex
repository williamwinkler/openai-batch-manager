defmodule BatcherWeb.Schemas.EmbeddingsRequestBodySchema do
  @moduledoc """
  OpenAPI schema for /v1/embeddings endpoint request body (text embeddings).
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.DeliverySchema

  OpenApiSpex.schema(%{
    type: :object,
    description: "Request body for /v1/embeddings endpoint (text embeddings)",
    required: [:custom_id, :model, :endpoint, :input, :delivery],
    properties: %{
      custom_id: %Schema{
        type: :string,
        description: "Unique identifier for this request (used to match request with response)",
        example: "emb-001"
      },
      model: %Schema{
        type: :string,
        description: "OpenAI embedding model to use (e.g., 'text-embedding-3-large', 'text-embedding-3-small')",
        example: "text-embedding-3-large"
      },
      endpoint: %Schema{
        type: :string,
        enum: ["/v1/embeddings"],
        description: "Must be '/v1/embeddings' for this request type"
      },
      input: %Schema{
        oneOf: [
          %Schema{
            type: :string,
            description: "Single text to embed",
            example: "The quick brown fox jumps over the lazy dog"
          },
          %Schema{
            type: :array,
            description: "Multiple texts to embed",
            items: %Schema{type: :string},
            example: ["First document", "Second document", "Third document"]
          }
        ],
        description: "Input text to embed - can be a single string or an array of strings"
      },
      delivery: DeliverySchema,
      dimensions: %Schema{
        type: :integer,
        minimum: 1,
        description: "Number of dimensions for the embedding vectors (only supported by text-embedding-3 models)",
        example: 1536
      },
      encoding_format: %Schema{
        type: :string,
        enum: ["float", "base64"],
        description: "Format to return embeddings in: 'float' (default) or 'base64'",
        example: "float"
      }
    },
    example: %{
      "custom_id" => Ecto.UUID.generate(),
      "model" => "text-embedding-3-large",
      "endpoint" => "/v1/embeddings",
      "input" => "The quick brown fox jumps over the lazy dog",
      "delivery" => %{
        "type" => "webhook",
        "webhook_url" => "https://api.example.com/embeddings"
      },
      "dimensions" => 1536
    }
  })
end
