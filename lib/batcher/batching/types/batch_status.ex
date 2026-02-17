defmodule Batcher.Batching.Types.BatchStatus do
  @moduledoc """
  Batch status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      building: [
        label: "Building",
        description: "Batch is being built and accepting new requests (auto uploads after 1h)"
      ],
      uploading: [
        label: "Uploading",
        description: "Batch file is being uploaded to OpenAI"
      ],
      uploaded: [
        label: "Uploaded",
        description: "Batch file has been uploaded to OpenAI"
      ],
      waiting_for_capacity: [
        label: "Waiting for capacity",
        description:
          "Batch is queued locally waiting for OpenAI queue headroom for this model. This is to avoid rate-limit errors"
      ],
      openai_processing: [
        label: "OpenAI processing",
        description: "OpenAI is processing the batch"
      ],
      openai_completed: [
        label: "OpenAI completed",
        description: "OpenAI has finished processing the batch"
      ],
      expired: [
        label: "Expired",
        description: "Batch expired on OpenAI and needs to be rescheduled"
      ],
      downloading: [
        label: "Downloading",
        description: "Batch results are being downloaded from OpenAI"
      ],
      downloaded: [
        label: "Downloaded",
        description: "Batch results have been downloaded"
      ],
      ready_to_deliver: [
        label: "Ready to deliver",
        description: "Results are ready to be delivered to the client"
      ],
      delivering: [
        label: "Delivering",
        description: "Results are being delivered to the client"
      ],
      delivered: [
        label: "Delivered",
        description: "All requests have been delivered successfully"
      ],
      partially_delivered: [
        label: "Partially delivered",
        description: "Some requests were delivered, but some failed"
      ],
      delivery_failed: [
        label: "Delivery failed",
        description: "All requests failed to deliver"
      ],
      failed: [
        label: "Failed",
        description: "Batch failed due to an error"
      ],
      cancelled: [
        label: "Cancelled",
        description: "Batch was cancelled"
      ],
      done: [
        label: "Done",
        description: "Batch processing is complete"
      ]
    ]
end
