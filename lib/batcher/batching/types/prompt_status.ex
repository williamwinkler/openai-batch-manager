defmodule Batcher.Batching.Types.PromptStatus do
  @moduledoc """
  Prompt status enum type for state machine.
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
