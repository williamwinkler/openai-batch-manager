defmodule Batcher.Batching.Types.RequestStatus do
  @moduledoc """
  Request status enum type for state machine.

  Terminal states: :delivered, :failed, :delivery_failed, :expired, :cancelled

  Note: :failed means OpenAI processing failed (request error)
        :delivery_failed means webhook delivery failed (delivery error)
  """
  use Ash.Type.Enum,
    values: [
      pending: [
        label: "Pending",
        description: "Request is waiting to be processed"
      ],
      openai_processing: [
        label: "OpenAI processing",
        description: "Request is being processed by OpenAI"
      ],
      openai_processed: [
        label: "OpenAI processed",
        description: "OpenAI has finished processing the request"
      ],
      delivering: [
        label: "Delivering",
        description: "Request result is being delivered"
      ],
      delivered: [
        label: "Delivered",
        description: "Request result has been delivered successfully"
      ],
      failed: [
        label: "Failed",
        description: "OpenAI processing failed"
      ],
      delivery_failed: [
        label: "Delivery failed",
        description: "Webhook delivery failed after all retry attempts"
      ],
      expired: [
        label: "Expired",
        description: "Request expired on OpenAI"
      ],
      cancelled: [
        label: "Cancelled",
        description: "Request was cancelled"
      ]
    ]
end
