defmodule BatcherWeb.Schemas.DeliveryConfigSchema do
  require OpenApiSpex
  alias OpenApiSpex.{Schema, Discriminator}
  alias BatcherWeb.Schemas.{DeliveryWebhookSchema, DeliveryRabbitMQSchema}

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
      DeliveryWebhookSchema.schema(),
      DeliveryRabbitMQSchema.schema()
    ]
  })
end
