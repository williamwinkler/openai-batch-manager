defmodule Batcher.OpenAPI.Schemas.DeliveryConfig do
  @moduledoc """
  Defines an OpenAPI schema used by the batcher API.
  """
  require OpenApiSpex
  alias OpenApiSpex.{Discriminator, Schema}
  alias Batcher.OpenAPI.Schemas.{DeliveryRabbitMQ, DeliveryWebhook}

  OpenApiSpex.schema(%Schema{
    title: "DeliveryConfig",
    description:
      "Delivery configuration for receiving results. Choose exactly one method via `type`. This won't be included in the request to OpenAI.",
    discriminator: %Discriminator{
      propertyName: "type",
      mapping: %{
        "webhook" => "#/components/schemas/DeliveryWebhook",
        "rabbitmq" => "#/components/schemas/DeliveryRabbitMQ"
      }
    },
    oneOf: [
      DeliveryWebhook,
      DeliveryRabbitMQ
    ]
  })
end
