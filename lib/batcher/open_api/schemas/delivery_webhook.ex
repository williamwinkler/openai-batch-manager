defmodule Batcher.OpenAPI.Schemas.DeliveryWebhook do
  @moduledoc """
  Defines an OpenAPI schema used by the batcher API.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    title: "DeliveryWebhook",
    description: "Deliver results via HTTP POST to the given webhook URL.",
    type: :object,
    required: [:type, :webhook_url],
    additionalProperties: false,
    properties: %{
      type: %Schema{
        type: :string,
        description: "Webhook delivery type. Must be 'webhook'.",
        enum: ["webhook"]
      },
      webhook_url: %Schema{
        type: :string,
        format: :uri,
        description: "HTTP/HTTPS endpoint that will receive result payloads via POST."
      }
    },
    example: %{
      "type" => "webhook",
      "webhook_url" => "https://api.example.com/webhook?auth=secret"
    }
  })
end
