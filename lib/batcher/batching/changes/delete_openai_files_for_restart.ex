defmodule Batcher.Batching.Changes.DeleteOpenaiFilesForRestart do
  use Ash.Resource.Change
  require Logger

  alias Batcher.OpenaiApiClient

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      batch = changeset.data

      files_to_delete = [
        {batch.openai_output_file_id, "output"},
        {batch.openai_error_file_id, "error"}
      ]

      Enum.each(files_to_delete, fn
        {nil, _type} ->
          :ok

        {file_id, type} ->
          case OpenaiApiClient.delete_file(file_id) do
            {:ok, _} ->
              Logger.info(
                "Deleted OpenAI #{type} file #{file_id} while restarting batch #{batch.id}"
              )

            {:error, :not_found} ->
              Logger.debug(
                "OpenAI #{type} file #{file_id} was not found while restarting batch #{batch.id}"
              )

            {:error, reason} ->
              Logger.warning(
                "Failed to delete OpenAI #{type} file #{file_id} while restarting batch #{batch.id}: #{inspect(reason)}"
              )
          end
      end)

      changeset
    end)
  end
end
