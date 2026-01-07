defmodule Batcher.Batching.Types.RequestStatus do
  @moduledoc """
  Request status enum type for state machine.

  Terminal states: :delivered, :failed, :delivery_failed, :expired, :cancelled

  Note: :failed means OpenAI processing failed (request error)
        :delivery_failed means webhook delivery failed (delivery error)
  """
  use Ash.Type.Enum,
    values: [
      :pending,
      :openai_processing,
      :openai_processed,
      :delivering,
      :delivered,
      :failed,
      :delivery_failed,
      :expired,
      :cancelled
    ]
end
