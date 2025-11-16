defmodule Batcher.Batching.Types.BatchStatus do
  @moduledoc """
  Batch status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      # Batch is being build
      :building,

      :uploading,

      # Batch file has been uploaded
      :uploaded,

      # Batch has been created in OpenAI
      :openai_batch_created,

      # OpenAI is validating the batch
      :openai_validating,

      # OpenAI is processing the batch
      :openai_processing,

      # OpenAI has completed the batch
      :openai_completed,

      # Batch file is being downloaded
      :downloading,

      # Batch file has been downloaded
      :downloaded,

      # Results are ready to be delivered to client
      :ready_to_deliver,

      # Delivering results to client
      :delivering,

      # All prompt results have been delivered
      :completed,
      # Batch failed for some reason
      :failed
    ]
end
