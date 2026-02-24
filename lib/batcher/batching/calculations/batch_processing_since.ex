defmodule Batcher.Batching.Calculations.BatchProcessingSince do
  @moduledoc """
  Returns the timestamp when the batch most recently entered the :openai_processing state,
  by looking up the latest matching transition record.
  """
  use Ash.Resource.Calculation

  alias Batcher.Repo
  alias Ecto.Adapters.SQL

  @impl true
  @doc false
  def calculate(records, _opts, _context) do
    batch_ids = Enum.map(records, & &1.id)

    timestamps = load_processing_since(batch_ids)

    Enum.map(records, fn record ->
      Map.get(timestamps, record.id)
    end)
  end

  defp load_processing_since([]), do: %{}

  defp load_processing_since(batch_ids) do
    query = """
    SELECT batch_id, MAX(transitioned_at) AS transitioned_at
    FROM batch_transitions
    WHERE batch_id = ANY($1) AND "to" = $2
    GROUP BY batch_id
    """

    %{rows: rows} = SQL.query!(Repo, query, [batch_ids, "openai_processing"])
    Map.new(rows, fn [batch_id, transitioned_at] -> {batch_id, transitioned_at} end)
  end
end
