defmodule Batcher.Batching.Types.RequestStatus do
  @moduledoc """
  Request status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      :pending,
      :openai_processing,
      :openai_processed,
      :delivering,
      :delivered,
      :failed,
      :expired,
      :cancelled
    ]
end
