defmodule Batcher.Batching.Validations.ValidateBatchSizeLimit do
  @moduledoc """
  Validates that adding a prompt won't exceed the 200 MB batch size limit.

  This validation acts as a safety net to ensure batch JSONL files never exceed
  OpenAI's 200 MB limit. The primary check happens in BatchBuilder GenServer for
  performance, but this validation provides data integrity guarantees.

  The validation:
  1. Gets the size of the current prompt (from request_payload_size)
  2. Sums the sizes of all existing prompts in the batch
  3. Ensures total doesn't exceed 200 MB

  ## Error

  Returns a validation error if the batch size limit would be exceeded.
  """
  use Ash.Resource.Validation

  alias Batcher.Batching.{BatchLimits, BatchQueries}
  alias Batcher.Utils.Format

  @impl true
  def validate(changeset, _opts, _context) do
    require Ash.Query

    # Only validate on create (not updates)
    if changeset.action_type != :create do
      :ok
    else
      batch_id = Ash.Changeset.get_attribute(changeset, :batch_id)
      prompt_size = Ash.Changeset.get_attribute(changeset, :request_payload_size)

      # If either is missing, let other validations handle it
      if is_nil(batch_id) or is_nil(prompt_size) do
        :ok
      else
        # Sum existing prompt sizes in this batch
        existing_size = BatchQueries.sum_prompt_sizes_in_batch(batch_id)
        total_size = existing_size + prompt_size

        if total_size > BatchLimits.max_batch_size_bytes() do
          {:error,
           field: :batch_id,
           message:
             "Adding this prompt would exceed the 200 MB batch size limit. " <>
               "Current batch size: #{Format.bytes(existing_size)}, " <>
               "prompt size: #{Format.bytes(prompt_size)}, " <>
               "total would be: #{Format.bytes(total_size)}"}
        else
          :ok
        end
      end
    end
  end
end
