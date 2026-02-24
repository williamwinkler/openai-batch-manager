defmodule Batcher.OpenAPI.Schemas.DeliveryRabbitMQ do
  @moduledoc """
  Defines an OpenAPI schema used by the batcher API.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    title: "DeliveryRabbitMQ",
    description:
      "Publish results to RabbitMQ queue. Provide rabbitmq_queue as the destination queue name.",
    type: :object,
    required: [:type, :rabbitmq_queue],
    additionalProperties: false,
    properties: %{
      type: %Schema{
        type: :string,
        description: "RabbitMQ delivery type. Must be 'rabbitmq'.",
        enum: ["rabbitmq"]
      },
      rabbitmq_queue: %Schema{
        type: :string,
        description: "Name of the queue to route to."
      }
    },
    example: %{
      "type" => "rabbitmq",
      "rabbitmq_queue" => "batching.results"
    }
  })
end
