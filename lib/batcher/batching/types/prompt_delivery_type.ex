defmodule Batcher.Batching.Types.RequestDeliveryType do
  @moduledoc """
  Request delivery type enum (webhook or rabbitmq).
  """
  use Ash.Type.Enum, values: [:webhook, :rabbitmq]
end
