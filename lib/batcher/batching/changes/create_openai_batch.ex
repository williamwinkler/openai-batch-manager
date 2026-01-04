defmodule Batcher.Batching.Changes.CreateOpenaiBatch do
  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data

    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      # Create batch on OpenAI before transaction starts in case it fails
      case Batcher.OpenaiApiClient.create_batch(batch.openai_input_file_id, batch.url) do
        {:ok, response} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:openai_batch_id, response["id"])

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "OpenAI batch creation failed: #{reason}")
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, batch ->
      # Bulk update all pending requests to processing after transaction
      Batcher.Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.filter(state == :pending)
      |> Ash.bulk_update!(:bulk_begin_processing, %{}, strategy: :atomic)

      {:ok, batch}
    end)
  end
end
