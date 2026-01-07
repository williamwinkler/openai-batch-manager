defmodule Batcher.Batching.Types.BatchStatus do
  @moduledoc """
  Batch status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      # Batch is being build
      :building,

      # Batch file is being uploaded
      :uploading,

      # Batch file has been uploaded
      :uploaded,

      # OpenAI is processing the batch
      :openai_processing,

      # OpenAI has completed the batch
      :openai_completed,

      # Batch expired on OpenAI and needs to be rescheduled
      :expired,

      # Batch file is being downloaded
      :downloading,

      # Batch file has been downloaded
      :downloaded,

      # Results are ready to be delivered to client
      :ready_to_deliver,

      # Delivering results to client
      :delivering,

      # All prompt results have been delivered
      :done,

      # Batch failed for some reason
      :failed,

      # Batch was cancelled
      :cancelled
    ]
end
