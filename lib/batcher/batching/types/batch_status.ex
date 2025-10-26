defmodule Batcher.Batching.Types.BatchStatus do
  @moduledoc """
  This describes the different statuses a can have batch.
  These statuses are inspired by the status from the OpenAI batch API.
  """

  use Ash.Type.Enum,
    values: [
      # Local states (before upload)
      draft: [
        description: "Batch is being built/filled with prompts",
        label: "Draft"
      ],
      ready_for_upload: [
        description: "Batch is ready to be uploaded",
        label: "Ready for upload"
      ],
      uploading: [
        description: "Uploading batch file to provider",
        label: "Uploading"
      ],

      # Provider states
      validating: [
        description: "Provider is validating the batch file",
        label: "Validating"
      ],
      in_progress: [
        description: "Batch is being processed by provider",
        label: "In Progress"
      ],
      finalizing: [
        description: "Provider is finalizing results",
        label: "Finalizing"
      ],

      # Download states
      downloading: [
        description: "Downloading results from provider",
        label: "Downloading"
      ],

      # Terminal states
      completed: [
        description: "Batch completed successfully, results downloaded",
        label: "Completed"
      ],
      failed: [
        description: "Batch failed validation or processing",
        label: "Failed"
      ],
      expired: [
        description: "Batch expired before completion (provider SLA)",
        label: "Expired"
      ],
      cancelled: [
        description: "Batch was cancelled",
        label: "Cancelled"
      ]
    ]
end
