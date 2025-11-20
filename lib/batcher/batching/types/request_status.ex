defmodule Batcher.Batching.Types.RequestStatus do
  @moduledoc """
  Request status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      :pending,
      :processing,
      :processed,
      :delivering,
      :delivered,
      :failed,
      :expired,
      :cancelled
    ]
end
