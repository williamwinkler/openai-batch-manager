defmodule Batcher.Batching.Validations.ValidatePromptMatchesBatch do
  @moduledoc """
  Validates that a prompt's provider and model arguments match the batch's provider and model.

  This ensures data consistency by preventing prompts with different providers or models
  from being added to a batch. The provider and model are passed as arguments during prompt
  creation but are not stored on the prompt itself - they must match the batch.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    batch_id = Ash.Changeset.get_attribute(changeset, :batch_id)
    prompt_provider = Ash.Changeset.get_argument(changeset, :provider)
    prompt_model = Ash.Changeset.get_argument(changeset, :model)

    # Only validate if all required fields are present
    if batch_id && prompt_provider && prompt_model do
      case Ash.get(Batcher.Batching.Batch, batch_id) do
        {:ok, batch} ->
          validate_match(batch, prompt_provider, prompt_model)

        {:error, _} ->
          {:error,
           field: :batch_id, message: "Batch with id #{batch_id} not found"}
      end
    else
      # If fields are missing, let other validations handle it
      :ok
    end
  end

  defp validate_match(batch, prompt_provider, prompt_model) do
    cond do
      batch.provider != prompt_provider ->
        {:error,
         field: :provider,
         message:
           "Provider '#{prompt_provider}' does not match batch provider '#{batch.provider}'"}

      batch.model != prompt_model ->
        {:error,
         field: :model,
         message: "Model '#{prompt_model}' does not match batch model '#{batch.model}'"}

      true ->
        :ok
    end
  end
end
