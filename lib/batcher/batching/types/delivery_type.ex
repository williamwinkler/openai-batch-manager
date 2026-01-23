defmodule Batcher.Batching.Types.DeliveryType do
  @moduledoc """
  Enum type for delivery configuration types.
  """
  use Ash.Type.Enum, values: [:webhook, :rabbitmq]

  @doc """
  Returns a list of {label, value} tuples for use in select inputs.
  """
  def options do
    [
      {"Webhook", "webhook"},
      {"RabbitMQ", "rabbitmq"}
    ]
  end
end
