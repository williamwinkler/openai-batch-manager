defmodule Mix.Tasks.Openapi.FixUnion do
  @moduledoc """
  Post-processes the generated OpenAPI spec to properly represent the union type
  with anyOf for the three different request body types.

  Usage:
    mix openapi.spec.json --spec BatcherWeb.AshJsonApiRouter
    mix openapi.fix_union
  """
  use Mix.Task

  @shortdoc "Fixes the OpenAPI spec to show anyOf for request body types"

  def run(_args) do
    openapi_file = "openapi.json"

    unless File.exists?(openapi_file) do
      Mix.shell().error("openapi.json not found. Run mix openapi.spec.json first.")
      System.halt(1)
    end

    spec = File.read!(openapi_file) |> Jason.decode!()

    # Fix the schema
    fixed_spec = fix_union_type(spec)

    # Write back
    File.write!(openapi_file, Jason.encode!(fixed_spec, pretty: true))
    Mix.shell().info("✓ Fixed openapi.json with proper anyOf schemas")
  end

  defp fix_union_type(spec) do
    # Create three separate schemas for each request body type
    schemas = %{
      "ResponsesRequestBody" => create_responses_schema(),
      "EmbeddingsRequestBody" => create_embeddings_schema(),
      "ModerationRequestBody" => create_moderation_schema(),
      "Delivery" => create_delivery_schema()
    }

    # Update the components/schemas
    updated_schemas = Map.merge(spec["components"]["schemas"], schemas)

    # Update the prompt_request_body-input-create-type to use anyOf
    updated_schemas =
      Map.put(updated_schemas, "prompt_request_body-input-create-type", %{
        "anyOf" => [
          %{"$ref" => "#/components/schemas/ResponsesRequestBody"},
          %{"$ref" => "#/components/schemas/EmbeddingsRequestBody"},
          %{"$ref" => "#/components/schemas/ModerationRequestBody"}
        ],
        "discriminator" => %{
          "propertyName" => "endpoint",
          "mapping" => %{
            "/v1/responses" => "#/components/schemas/ResponsesRequestBody",
            "/v1/embeddings" => "#/components/schemas/EmbeddingsRequestBody",
            "/v1/moderations" => "#/components/schemas/ModerationRequestBody"
          }
        }
      })

    put_in(spec, ["components", "schemas"], updated_schemas)
  end

  defp create_delivery_schema do
    %{
      "type" => "object",
      "description" => "Delivery configuration for receiving results",
      "required" => ["type"],
      "properties" => %{
        "type" => %{
          "type" => "string",
          "enum" => ["webhook", "rabbitmq"],
          "description" =>
            "Delivery type: 'webhook' for HTTP POST delivery, 'rabbitmq' for message queue delivery"
        },
        "webhook_url" => %{
          "type" => "string",
          "description" => "HTTP/HTTPS URL to receive results (required when type is 'webhook')",
          "format" => "uri"
        },
        "rabbitmq_queue" => %{
          "type" => "string",
          "description" =>
            "RabbitMQ queue name to receive results (required when type is 'rabbitmq')"
        }
      },
      "oneOf" => [
        %{
          "properties" => %{
            "type" => %{"const" => "webhook"},
            "webhook_url" => %{"type" => "string", "format" => "uri"}
          },
          "required" => ["type", "webhook_url"]
        },
        %{
          "properties" => %{
            "type" => %{"const" => "rabbitmq"},
            "rabbitmq_queue" => %{"type" => "string"}
          },
          "required" => ["type", "rabbitmq_queue"]
        }
      ]
    }
  end

  defp create_responses_schema do
    %{
      "type" => "object",
      "description" =>
        "Request body for /v1/responses endpoint (chat completions/responses)",
      "required" => ["custom_id", "model", "endpoint", "input", "delivery"],
      "properties" => %{
        "custom_id" => %{
          "type" => "string",
          "description" => "Unique identifier for this request (used to match request with response)"
        },
        "model" => %{
          "type" => "string",
          "description" => "OpenAI model to use (e.g., 'gpt-4o', 'gpt-3.5-turbo')",
          "example" => "gpt-4o"
        },
        "endpoint" => %{
          "type" => "string",
          "const" => "/v1/responses",
          "description" => "Must be '/v1/responses' for this request type"
        },
        "input" => %{
          "oneOf" => [
            %{"type" => "string", "description" => "Plain text input"},
            %{
              "type" => "array",
              "description" => "Conversation messages",
              "items" => %{
                "type" => "object",
                "required" => ["role", "content"],
                "properties" => %{
                  "role" => %{
                    "type" => "string",
                    "enum" => ["developer", "user", "assistant"]
                  },
                  "content" => %{"type" => "string"}
                }
              }
            }
          ],
          "description" =>
            "Input text (string) or conversation messages (array of message objects with 'role' and 'content')"
        },
        "delivery" => %{
          "$ref" => "#/components/schemas/Delivery",
          "description" => "Delivery configuration specifying how to receive the response"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "System instructions for the model"
        },
        "temperature" => %{
          "type" => "number",
          "minimum" => 0,
          "maximum" => 2,
          "description" => "Sampling temperature (0-2). Higher values make output more random"
        },
        "max_output_tokens" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "Maximum number of tokens to generate in the response"
        },
        "top_p" => %{
          "type" => "number",
          "minimum" => 0,
          "maximum" => 1,
          "description" => "Nucleus sampling parameter (0-1). Alternative to temperature"
        },
        "store" => %{
          "type" => "boolean",
          "default" => true,
          "description" =>
            "Whether to store the response for later retrieval via API (default: true)"
        }
      }
    }
  end

  defp create_embeddings_schema do
    %{
      "type" => "object",
      "description" => "Request body for /v1/embeddings endpoint (text embeddings)",
      "required" => ["custom_id", "model", "endpoint", "input", "delivery"],
      "properties" => %{
        "custom_id" => %{
          "type" => "string",
          "description" => "Unique identifier for this request (used to match request with response)"
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "OpenAI embedding model to use (e.g., 'text-embedding-3-large', 'text-embedding-3-small')",
          "example" => "text-embedding-3-large"
        },
        "endpoint" => %{
          "type" => "string",
          "const" => "/v1/embeddings",
          "description" => "Must be '/v1/embeddings' for this request type"
        },
        "input" => %{
          "oneOf" => [
            %{"type" => "string", "description" => "Single text to embed"},
            %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Multiple texts to embed"
            }
          ],
          "description" => "Input text to embed - can be a single string or an array of strings"
        },
        "delivery" => %{
          "$ref" => "#/components/schemas/Delivery",
          "description" => "Delivery configuration specifying how to receive the embeddings"
        },
        "dimensions" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" =>
            "Number of dimensions for the embedding vectors (only supported by text-embedding-3 models)"
        },
        "encoding_format" => %{
          "type" => "string",
          "enum" => ["float", "base64"],
          "description" => "Format to return embeddings in: 'float' (default) or 'base64'"
        }
      }
    }
  end

  defp create_moderation_schema do
    %{
      "type" => "object",
      "description" => "Request body for /v1/moderations endpoint (content moderation)",
      "required" => ["custom_id", "model", "endpoint", "input", "delivery"],
      "properties" => %{
        "custom_id" => %{
          "type" => "string",
          "description" => "Unique identifier for this request (used to match request with response)"
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "OpenAI moderation model to use (e.g., 'omni-moderation-latest', 'text-moderation-latest')",
          "example" => "omni-moderation-latest"
        },
        "endpoint" => %{
          "type" => "string",
          "const" => "/v1/moderations",
          "description" => "Must be '/v1/moderations' for this request type"
        },
        "input" => %{
          "oneOf" => [
            %{"type" => "string", "description" => "Single text to moderate"},
            %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Multiple texts to moderate"
            }
          ],
          "description" => "Input text to moderate - can be a single string or an array of strings"
        },
        "delivery" => %{
          "$ref" => "#/components/schemas/Delivery",
          "description" =>
            "Delivery configuration specifying how to receive the moderation results"
        }
      }
    }
  end
end
