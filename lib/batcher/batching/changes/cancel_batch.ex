defmodule Batcher.Batching.Changes.CancelBatch do
  use Ash.Resource.Change
  require Ash.Query
  require Logger

  alias Batcher.Batching.ObanJobs

  @cancellable_request_states [:pending, :openai_processing, :openai_processed, :delivering]

  @impl true
  def change(changeset, _opts, _ctx) do
    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      batch = changeset.data

      if batch.state == :openai_processing and batch.openai_batch_id do
        Logger.info("Cancelling OpenAI batch #{batch.openai_batch_id} for batch #{batch.id}")

        case Batcher.OpenaiApiClient.cancel_batch(batch.openai_batch_id) do
          {:ok, _} ->
            Logger.info(
              "Successfully cancelled OpenAI batch #{batch.openai_batch_id} for batch #{batch.id}"
            )

            changeset

          {:error, :not_found} ->
            Logger.info(
              "OpenAI batch #{batch.openai_batch_id} not found (may already be cancelled) for batch #{batch.id}"
            )

            changeset

          {:error, error} ->
            Logger.error(
              "Failed to cancel OpenAI batch #{batch.openai_batch_id} for batch #{batch.id}: #{inspect(error)}"
            )

            changeset
            |> Ash.Changeset.add_error("Failed to cancel OpenAI batch: #{inspect(error)}")
        end
      else
        changeset
      end
    end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      case result do
        {:ok, batch} ->
          cancel_oban_jobs(batch.id)
          cancel_requests(batch.id)
          {:ok, batch}

        {:error, _error} = error ->
          error
      end
    end)
  end

  defp cancel_oban_jobs(batch_id) do
    case ObanJobs.cancel_batch_jobs(batch_id) do
      :ok ->
        :ok

      {:error, errors} ->
        Logger.error("Failed to cancel Oban jobs for batch #{batch_id}: #{inspect(errors)}")
    end
  end

  defp cancel_requests(batch_id) do
    Logger.info("Cancelling requests for batch #{batch_id}")

    Batcher.Batching.Request
    |> Ash.Query.filter(batch_id == ^batch_id)
    |> Ash.Query.filter(state in ^@cancellable_request_states)
    |> Ash.bulk_update!(:cancel, %{}, strategy: :stream)
  end
end
