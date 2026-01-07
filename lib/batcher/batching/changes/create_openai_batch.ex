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
          error_msg =
            case reason do
              {:bad_request, body} ->
                message = Map.get(body, "error", %{}) |> Map.get("message", "Bad request")
                "OpenAI batch creation failed: #{message}"

              atom when is_atom(atom) ->
                "OpenAI batch creation failed: #{atom}"

              other ->
                "OpenAI batch creation failed: #{inspect(other)}"
            end

          Ash.Changeset.add_error(changeset, error_msg)
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, batch ->
      # Bulk update all pending requests to processing after transaction
      Batcher.Batching.Request
      |> Ash.Query.filter(batch_id == ^batch.id)
      |> Ash.Query.filter(state == :pending)
      |> Ash.bulk_update!(:bulk_begin_processing, %{}, strategy: :stream)

      {:ok, batch}
    end)
  end
end
