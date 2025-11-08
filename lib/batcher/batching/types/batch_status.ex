defmodule Batcher.Batching.Types.BatchStatus do
  @moduledoc """
  Batch status enum type for state machine.
  """
  use Ash.Type.Enum,
    values: [
      :draft,
      :ready_for_upload,
      :uploading,
      :validating,
      :in_progress,
      :finalizing,
      :downloading,
      :completed,
      :failed,
      :expired,
      :cancelled
    ]
end
