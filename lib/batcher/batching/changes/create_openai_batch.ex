defmodule Batcher.Batching.Changes.CreateOpenaiBatch do
  use Ash.Resource.Change
  require Logger

  alias Batcher.Batching

  @impl true
  def change(changeset, _opts, _context) do
    batch = changeset.data

    latest_batch = Batching.get_batch_by_id!(batch.id)

    valid_state? =
      latest_batch.state == :uploaded or
        (latest_batch.state == :expired and is_nil(latest_batch.openai_output_file_id) and
           is_nil(latest_batch.openai_error_file_id))

    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      cond do
        not valid_state? ->
          Logger.info(
            "Skipping create_openai_batch for batch #{batch.id}, invalid state #{inspect(latest_batch.state)}"
          )

          Ash.Changeset.add_error(
            changeset,
            "Batch #{batch.id} is no longer in a state that can create an OpenAI batch (current state: #{latest_batch.state})"
          )

        is_nil(latest_batch.openai_input_file_id) ->
          Ash.Changeset.add_error(
            changeset,
            "Batch #{batch.id} has no input file id for OpenAI batch creation"
          )

        true ->
          # Create batch on OpenAI before transaction starts in case it fails
          case Batcher.OpenaiApiClient.create_batch(latest_batch.openai_input_file_id, batch.url) do
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
