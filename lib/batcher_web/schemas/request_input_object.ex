defmodule BatcherWeb.Schemas.RequestInputObject do
  alias OpenApiSpex.Schema
  alias BatcherWeb.Schemas.DeliverySchema

  @behaviour OpenApiSpex.Schema

  @impl true
  def schema do
    %Schema{
      title: "RequestInputObject",
      description: "The per-line object of the batch input file + delivery instructions.",
      type: :object,
      required: [:custom_id, :url, :method, :body, :delivery],
      additionalProperties: false,
      properties: %{
        custom_id: %Schema{
          type: :string,
          description:
            "A developer-provided per-request id that will be used to match outputs to inputs. Must be unique for each request in a batch.",
          example: "my-custom-id-123"
        },
        url: %Schema{
          type: :string,
          enum: [
            "/v1/responses",
            "/v1/embeddings",
            "/v1/moderations",
            "/v1/chat/completions",
            "/v1/completions"
          ],
          description:
            "The OpenAI API relative URL to be used for the request."
        },
        method: %Schema{
          type: :string,
          enum: ["POST"],
          description:
            "The HTTP method to be used for the request. Currently only 'POST' is supported."
        },
        delivery: DeliverySchema.schema(),
        body: body_schema()
      },
      # example: %{
      #   "method" => "POST",
      #   "url" => "/v1/responses",
      #   "custom_id" => "2a6c0a28-95d0-412f-bf50-f598dd541630",
      #   "delivery" => %{
      #     "type" => "webhook",
      #     "webhook_url" => "https://api.example.com/webhook?auth=secret"
      #   },
      #   "body" => %{
      #     "model" => "gpt-4o-mini",
      #     "input" => [
      #       %{"role" => "developer", "content" => "You are a helpful assistant"},
      #       %{"role" => "user", "content" => "Tell me a joke."}
      #     ],
      #     "temperature" => 0.7,
      #     "max_output_tokens" => 500
      #   }
      # }
    }
  end

  # Shared body schema for responses/embeddings/moderations
  defp body_schema do
    %Schema{
      type: :object,
      required: [:model, :input],
      properties: %{
        model: %Schema{
          type: :string,
          description: "OpenAI model (e.g., gpt-4o-mini, text-embedding-3-large).",
          example: "gpt-4o-mini"
        },
        input: %Schema{
          oneOf: [
            %Schema{
              type: :string,
              description: "Plain text input.",
              example: "Explain quantum computing in simple terms."
            },
            %Schema{
              type: :array,
              description:
                "Array input. For responses: array of message objects; for embeddings/moderations: provider-accepted array.",
              items: %Schema{
                type: :object,
                description: "Message or item object.",
                properties: %{
                  role: %Schema{
                    type: :string,
                    enum: ["system", "user", "assistant", "developer"],
                    description: "For /v1/responses message arrays."
                  },
                  content: %Schema{
                    type: :string,
                    description: "Content string for message objects."
                  }
                }
              }
            }
          ],
          description: "String or array input"
        }
      },
      additionalProperties: true,
      description:
        "Common body for responses/embeddings/moderations. Includes required model and input; other fields are pass-through."
    }
  end
end
