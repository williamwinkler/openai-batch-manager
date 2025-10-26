defmodule Batcher.Batching.Changes.CreateBatchFile do
  @moduledoc """
  Creates a physical JSONL file for a batch after it's created in the database.

  This change runs in the after_action hook to ensure the batch has an ID before
  creating the file. It performs the following steps:

  1. Checks that at least 10MB of disk space is available
  2. Ensures the batch storage directory exists
  3. Creates an empty .jsonl file named batch_<id>.jsonl

  If any step fails, the batch creation is rolled back.

  ## Example

      # In a resource's create action:
      create :create do
        accept [:provider, :model]
        change Batcher.Batching.Changes.CreateBatchFile
      end
  """
  use Ash.Resource.Change

  alias Batcher.Batching.BatchFile

  @impl true
  def change(changeset, _opts, _ctx) do
    # Only run for create actions
    if changeset.action_type == :create do
      Ash.Changeset.after_action(changeset, fn _cs, batch ->
        with {:ok, _space} <- BatchFile.check_disk_space(),
             :ok <- BatchFile.ensure_directory_exists(),
             {:ok, _path} <- BatchFile.create_file(batch.id) do
          {:ok, batch}
        else
          {:error, reason} ->
            {:error,
             Ash.Error.Changes.InvalidChanges.exception(
               message: "Failed to create batch file: #{reason}",
               field: :id
             )}
        end
      end)
    else
      changeset
    end
  end
end
