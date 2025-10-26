defmodule Batcher.Batching.Types.PromptStatus do
  use Ash.Type.Enum,
    values: [
      # Initial states
      pending: [
        description: "Prompt received, waiting to be processed",
        label: "Pending"
      ],

      # Processing states (mirrors batch)
      processing: [
        description: "Batch is being processed by provider",
        label: "Processing"
      ],

      # Post-processing states
      processed: [
        description: "Response received from provider, pending delivery",
        label: "Processed"
      ],
      delivering: [
        description: "Delivering response to RabbitMQ/webhook",
        label: "Delivering"
      ],

      # Terminal states
      delivered: [
        description: "Successfully delivered to destination",
        label: "Delivered"
      ],
      failed: [
        description: "Processing or delivery failed",
        label: "Failed"
      ],
      expired: [
        description: "Batch expired before processing completed",
        label: "Expired"
      ],
      cancelled: [
        description: "Prompt was cancelled",
        label: "Cancelled"
      ]
    ]
end
