defmodule Batcher.Batching.Types.DeliveryType do
  @moduledoc """
  Enum type for delivery configuration types.
  """
  use Ash.Type.Enum,
    values: [
      webhook: [label: "Webhook", description: "Deliver via HTTP POST to a webhook URL"],
      rabbitmq: [label: "RabbitMQ", description: "Deliver via RabbitMQ message queue"]
    ]
end
