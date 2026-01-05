defmodule Batcher.Batching.Calculations.BatchRequestCount do
  @moduledoc """
  Calculation to count the number of requests in a batch.
  This is done in the application since SQLite does not support it natively.
  """
  use Ash.Resource.Calculation

  require Ash.Query
  alias Batcher.Batching.Request

  @impl true
  def calculate(records, _opts, _context) do
    # record is a batch here
    Enum.map(records, fn record ->
      Request
      |> Ash.Query.filter(batch_id == ^record.id)
      |> Ash.count!()
    end)
  end
end
