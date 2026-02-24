defmodule Batcher.Batching.Calculations.BatchRequestsTerminal do
  @moduledoc """
  Calculation to check if all requests in a batch are in terminal states.

  Terminal states are: :delivered, :failed, :delivery_failed, :expired, :cancelled
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL
  alias Batcher.Repo

  @terminal_states [:delivered, :failed, :delivery_failed, :expired, :cancelled]

  @impl true
  @doc false
  def calculate(records, _opts, _context) do
    batch_ids = Enum.map(records, & &1.id)
    non_terminal_by_batch_id = load_non_terminal_counts(batch_ids)

    Enum.map(records, fn record ->
      Map.get(non_terminal_by_batch_id, record.id, 0) == 0
    end)
  end

  defp load_non_terminal_counts([]), do: %{}

  defp load_non_terminal_counts(batch_ids) do
    query = """
    SELECT batch_id, COUNT(*)::bigint AS non_terminal_count
    FROM requests
    WHERE batch_id = ANY($1)
      AND state <> ALL($2)
    GROUP BY batch_id
    """

    terminal_states = Enum.map(@terminal_states, &to_string/1)
    %{rows: rows} = SQL.query!(Repo, query, [batch_ids, terminal_states])

    Map.new(rows, fn [batch_id, non_terminal_count] -> {batch_id, non_terminal_count} end)
  end
end
