defmodule BatcherWeb.Schemas.RequestInputObject do
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.DeliveryConfigSchema

  @behaviour OpenApiSpex.Schema

  @impl true
  def schema do
    %Schema{
      title: "RequestInputObject",
      description: "The per-line object of the batch input file + delivery instructions.",
      type: :object,
      required: [:custom_id, :url, :method, :body, :delivery_config],
      additionalProperties: false,
      properties: %{
        custom_id: %Schema{
          type: :string,
          description:
            "A developer-provided per-request id that will be used to match outputs to inputs. Must be globally unique across all requests.\nRecommended format: `<action>_<unique_id>` (e.g., `analyzeWebsite_abc123`) to help categorize results by action type when processed.",
          example: "ask_capital_550e8400-e29b-41d4-a716-446655440000"
        },
        url: %Schema{
          type: :string,
          enum: Batcher.Batching.Types.OpenaiBatchEndpoints.values(),
          description: "The OpenAI API relative URL to be used for the request."
        },
        method: %Schema{
          type: :string,
          enum: ["POST"],
          description:
            "The HTTP method to be used for the request. Currently only 'POST' is supported."
        },
        delivery_config: DeliveryConfigSchema,
        body: body_schema()
      },
      example: %{
        "method" => "POST",
        "url" => "/v1/responses",
        "custom_id" => "ask_capital_550e8400-e29b-41d4-a716-446655440000",
        "delivery_config" => %{
          "type" => "webhook",
          "webhook_url" => "https://api.example.com/webhook?auth=secret"
        },
        "body" => %{
          "model" => "gpt-4o-mini",
          "input" => "What is the capital of France?",
          "text" => %{
            "format" => %{
              "type" => "json_schema",
              "name" => "answer",
              "schema" => %{
                "type" => "object",
                "properties" => %{
                  "answer" => %{"type" => "string"}
                },
                "required" => ["answer"],
                "additionalProperties" => false
              }
            }
          }
        }
      }
    }
  end

  # Shared body schema for all supported endpoints
  defp body_schema do
    %Schema{
      type: :object,
      required: [:model],
      properties: %{
        model: %Schema{
          type: :string,
          description: "OpenAI model (e.g., gpt-4o-mini, text-embedding-3-large, gpt-4o).",
          example: "gpt-4o-mini"
        },
        input: %Schema{
          oneOf: [
            %Schema{
              type: :string,
              description:
                "Plain text input (for /v1/responses, /v1/embeddings, /v1/moderations).",
              example: "Explain quantum computing in simple terms."
            },
            %Schema{
              type: :array,
              description:
                "Array of message objects for /v1/responses. For /v1/embeddings and /v1/moderations, use an array of strings instead.",
              items: %Schema{
                type: :object,
                description: "Message object.",
                properties: %{
                  role: %Schema{
                    type: :string,
                    enum: ["system", "user", "assistant", "developer"],
                    description: "Message role."
                  },
                  content: %Schema{
                    type: :string,
                    description: "Message content."
                  }
                }
              }
            }
          ],
          description:
            "Input field for /v1/responses, /v1/embeddings, and /v1/moderations endpoints."
        },
        messages: %Schema{
          type: :array,
          description: "Messages array for /v1/chat/completions endpoint.",
          items: %Schema{
            type: :object,
            properties: %{
              role: %Schema{
                type: :string,
                enum: ["system", "user", "assistant", "developer"],
                description: "Message role."
              },
              content: %Schema{
                type: :string,
                description: "Message content."
              }
            }
          },
          example: [
            %{"role" => "system", "content" => "You are a helpful assistant."},
            %{"role" => "user", "content" => "Tell me a joke."}
          ]
        },
        prompt: %Schema{
          oneOf: [
            %Schema{
              type: :string,
              description: "Prompt string for /v1/completions endpoint.",
              example: "The capital of France is"
            },
            %Schema{
              type: :array,
              items: %Schema{
                type: :string
              },
              description: "Array of prompt strings for /v1/completions endpoint."
            }
          ],
          description: "Prompt field for /v1/completions endpoint (string or array of strings)."
        }
      },
      additionalProperties: true,
      description: """
      Request body structure varies by endpoint:
      - /v1/responses: requires 'model' and 'input' (string or array of messages)
      - /v1/chat/completions: requires 'model' and 'messages' (array of message objects)
      - /v1/completions: requires 'model' and 'prompt' (string or array of strings)
      - /v1/embeddings: requires 'model' and 'input' (string or array of strings)
      - /v1/moderations: requires 'model' and 'input' (string or array of strings)

      All other fields are pass-through to OpenAI's API.
      """
    }
  end
end
