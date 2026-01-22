defmodule Batcher.Batching.Calculations.BatchDeliveryStats do
  @moduledoc """
  Calculation to get delivery statistics for a batch.

  Returns a map with counts of delivered and failed requests:
  - delivered: count of requests in :delivered state
  - failed: count of requests in terminal failure states (:delivery_failed, :failed, :expired, :cancelled)
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.Request

  @delivered_states [:delivered]
  @failed_states [:delivery_failed, :failed, :expired, :cancelled]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      delivered_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state in ^@delivered_states)
        |> Ash.count!()

      failed_count =
        Request
        |> Ash.Query.filter(batch_id == ^record.id)
        |> Ash.Query.filter(state in ^@failed_states)
        |> Ash.count!()

      %{delivered: delivered_count, failed: failed_count}
    end)
  end
end
