defmodule Batcher.Batching.Types.PromptDeliveryType do
  @moduledoc """
  Prompt delivery type enum (webhook or rabbitmq).
  """
  use Ash.Type.Enum, values: [:webhook, :rabbitmq]
end
