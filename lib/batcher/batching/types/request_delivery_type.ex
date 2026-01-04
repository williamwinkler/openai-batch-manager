defmodule Batcher.Batching.Types.RequestDeliveryType do
  @moduledoc """
  Request delivery type enum.
  """
  use Ash.Type.Enum, values: [:webhook, :rabbitmq]
end
