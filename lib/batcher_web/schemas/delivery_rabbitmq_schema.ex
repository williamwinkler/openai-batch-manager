defmodule BatcherWeb.Schemas.DeliveryRabbitMQSchema do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    title: "DeliveryRabbitMQ",
    description:
      "Publish results to RabbitMQ. Two modes: (1) Default exchange mode - provide rabbitmq_queue to route directly to the queue; (2) Custom exchange mode - provide rabbitmq_exchange and rabbitmq_routing_key to route via an exchange.",
    type: :object,
    required: [:type],
    additionalProperties: false,
    properties: %{
      type: %Schema{
        type: :string,
        description: "RabbitMQ delivery type. Must be 'rabbitmq'.",
        enum: ["rabbitmq"]
      },
      rabbitmq_queue: %Schema{
        type: :string,
        description:
          "Name of the queue to route to. Required when using the default exchange (no rabbitmq_exchange). Optional when using a custom exchange."
      },
      rabbitmq_exchange: %Schema{
        type: :string,
        description:
          "Name of the RabbitMQ exchange to publish to. When set, rabbitmq_routing_key is required and rabbitmq_queue becomes optional."
      },
      rabbitmq_routing_key: %Schema{
        type: :string,
        description:
          "Routing key for publishing to the exchange. Required when rabbitmq_exchange is set."
      }
    },
    example: %{
      "type" => "rabbitmq",
      "rabbitmq_exchange" => "batching.results",
      "rabbitmq_routing_key" => "requests.completed"
    }
  })
end
