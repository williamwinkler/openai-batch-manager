defmodule Batcher.Batching.Actions.DeleteExpiredBatch do
  @moduledoc """
  Runs an Ash action callback for the batch/request workflow.
  """
  use Ash.Resource.Actions.Implementation
  require Logger

  alias Batcher.Batching
  alias Batcher.Batching.Utils

  @impl true
  @doc false
  def run(input, _opts, _context) do
    batch_id = Utils.extract_subject_id(input)
    batch = Batching.get_batch_by_id!(batch_id)

    Logger.info("Deleting expired batch #{batch.id} (expired at #{batch.expires_at})")

    case Ash.destroy(batch) do
      :ok -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end
end
