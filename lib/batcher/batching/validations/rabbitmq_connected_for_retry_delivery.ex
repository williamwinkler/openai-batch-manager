defmodule Batcher.Batching.Validations.RabbitmqConnectedForRetryDelivery do
  @moduledoc """
  Prevents retry_delivery for RabbitMQ destinations when the publisher is disconnected.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    delivery_config =
      Ash.Changeset.get_attribute(changeset, :delivery_config) || changeset.data.delivery_config ||
        %{}

    if rabbitmq_delivery?(delivery_config) and not Batcher.RabbitMQ.Publisher.connected?() do
      {:error,
       field: :delivery_config,
       message: "RabbitMQ is disconnected. Reconnect RabbitMQ before retrying delivery."}
    else
      :ok
    end
  end

  defp rabbitmq_delivery?(delivery_config) when is_map(delivery_config) do
    Map.get(delivery_config, "type") == "rabbitmq" or
      Map.get(delivery_config, :type) == "rabbitmq"
  end

  defp rabbitmq_delivery?(_), do: false
end
