defmodule Batcher.Batching.Types.PromptDeliveryType do
  @moduledoc """
  This module defines the possible delivery options for
  the result of a succesfully processed prompt.
  """
  use Ash.Type.Enum,
    values: [
      rabbitmq: [
        description: "The prompt result will be delivered via RabbitMQ",
        label: "RabbitMQ"
      ],
      webhook: [
        description: "The prompt result will be delivered via webhook",
        label: "Webhook"
      ]
    ]
end
