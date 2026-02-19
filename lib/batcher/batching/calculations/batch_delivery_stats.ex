defmodule Batcher.Batching.Calculations.BatchDeliveryStats do
  @moduledoc """
  Calculation to get delivery statistics for a batch.

  Returns a map with counts of:
  - delivered: count of requests in :delivered state
  - delivering: count of requests in :delivering state
  - failed: count of requests that failed during delivery (:delivery_failed)
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.Request

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      delivered_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state == :delivered)
        |> Ash.count!()

      delivering_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state == :delivering)
        |> Ash.count!()

      failed_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state == :delivery_failed)
        |> Ash.count!()

      %{delivered: delivered_count, delivering: delivering_count, failed: failed_count}
    end)
  end
end
