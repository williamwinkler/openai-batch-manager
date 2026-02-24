defmodule Batcher.Batching.Calculations.BatchDeliveryStats do
  @moduledoc """
  Calculation to get delivery statistics for a batch.

  Returns a map with counts of:
  - delivered: count of requests in :delivered state
  - queued: count of requests waiting to begin delivery (:openai_processed)
  - delivering: count of requests in :delivering state
  - failed: count of requests that failed during delivery (:delivery_failed)
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL
  alias Batcher.Repo

  @impl true
  @doc false
  def calculate(records, _opts, _context) do
    batch_ids = Enum.map(records, & &1.id)
    stats_by_batch_id = load_stats_by_batch_id(batch_ids)

    Enum.map(records, fn record ->
      Map.get(stats_by_batch_id, record.id, %{delivered: 0, queued: 0, delivering: 0, failed: 0})
    end)
  end

  defp load_stats_by_batch_id([]), do: %{}

  defp load_stats_by_batch_id(batch_ids) do
    query = """
    SELECT batch_id, state, COUNT(*)::bigint AS count
    FROM requests
    WHERE batch_id = ANY($1)
      AND state IN ('delivered', 'openai_processed', 'delivering', 'delivery_failed')
    GROUP BY batch_id, state
    """

    %{rows: rows} = SQL.query!(Repo, query, [batch_ids])

    Enum.reduce(rows, %{}, fn [batch_id, state, count], acc ->
      metric =
        case state do
          "delivered" -> :delivered
          "openai_processed" -> :queued
          "delivering" -> :delivering
          "delivery_failed" -> :failed
        end

      Map.update(
        acc,
        batch_id,
        %{delivered: 0, queued: 0, delivering: 0, failed: 0} |> Map.put(metric, count),
        &Map.put(&1, metric, count)
      )
    end)
  end
end
