defmodule Batcher.Batching.Changes.RecoverFailedDownload do
  @moduledoc """
  Preserves delivered work while recovering a batch that failed during download.
  """
  use Ash.Resource.Change

  alias Batcher.Batching.DownloadRecovery

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      batch = changeset.data

      case DownloadRecovery.prepare_failed_batch(batch) do
        {:ok, _result} ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            "Failed to prepare batch download recovery: #{inspect(reason)}"
          )
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, batch ->
      DownloadRecovery.finalize_failed_batch(batch)
    end)
  end
end
