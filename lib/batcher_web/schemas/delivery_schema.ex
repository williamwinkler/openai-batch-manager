defmodule BatcherWeb.Schemas.DeliverySchema do
  @moduledoc """
  Delivery configuration. Exactly one of:
  - webhook: { type: "webhook", webhook_url }
  - rabbitmq: { type: "rabbitmq", rabbitmq_exchange, rabbitmq_queue }
  """
  require OpenApiSpex
  alias OpenApiSpex.{Schema, Discriminator}

  OpenApiSpex.schema(%Schema{
    title: "Delivery",
    description:
      "Delivery configuration for receiving results. Choose exactly one method via `type`.",
    discriminator: %Discriminator{
      propertyName: "type",
      mapping: %{
        "webhook" => "#/components/schemas/DeliveryWebhook",
        "rabbitmq" => "#/components/schemas/DeliveryRabbitMQ"
      }
    },
    oneOf: [
      %Schema{
        title: "DeliveryWebhook",
        description: "Deliver results via HTTP POST to the given webhook URL.",
        type: :object,
        required: [:type, :webhook_url],
        additionalProperties: false,
        properties: %{
          type: %Schema{type: :string, enum: ["webhook"], description: "Webhook delivery."},
          webhook_url: %Schema{
            type: :string,
            format: :uri,
            description: "HTTPS endpoint that will receive result payloads via POST."
          }
        },
        example: %{
          "type" => "webhook",
          "webhook_url" => "https://api.example.com/webhook?auth=secret"
        }
      },
      %Schema{
        title: "DeliveryRabbitMQ",
        description:
          "Publish results to a RabbitMQ exchange; server binds/ensures the target queue receives them.",
        type: :object,
        required: [:type, :rabbitmq_exchange, :rabbitmq_queue],
        additionalProperties: false,
        properties: %{
          type: %Schema{type: :string, enum: ["rabbitmq"], description: "RabbitMQ delivery."},
          rabbitmq_exchange: %Schema{
            type: :string,
            description: "Name of the RabbitMQ exchange to publish to."
          },
          rabbitmq_queue: %Schema{
            type: :string,
            description:
              "Name of the queue that should receive the messages. The server will ensure it is bound to the exchange."
          }
        },
        example: %{
          "type" => "rabbitmq",
          "rabbitmq_exchange" => "batcher.results",
          "rabbitmq_queue" => "results_queue"
        }
      }
    ]
  })
end
